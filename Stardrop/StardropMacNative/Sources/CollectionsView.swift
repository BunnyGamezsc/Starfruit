import SwiftUI
import UniformTypeIdentifiers

struct CollectionsView: View {
    @EnvironmentObject private var modManager: ModManager
    @EnvironmentObject private var nexusClient: NexusClient

    var body: some View {
        CollectionsContentView(manager: modManager.collectionManager, nexusClient: nexusClient)
    }
}

private struct CollectionsContentView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @ObservedObject var manager: CollectionManager
    @ObservedObject var nexusClient: NexusClient
    @NativeState private var link = ""
    @NativeState private var importing = false
    @NativeState private var targetEntry: (collectionID: String, entryID: String)?
    @NativeState private var removing: NativeCollection?
    @NativeState private var addonCollectionID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(nativeLocalized("Collections")).font(.title2.bold())
                Spacer()
                Button(nativeLocalized("Check Revisions")) { manager.checkForUpdates(nexusClient: nexusClient) }
                    .disabled(manager.collections.isEmpty || manager.isResolving)
            }
            HStack {
                TextField(nativeLocalized("Paste a Nexus collection URL or nxm:// link"), text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(importLink)
                Button(manager.isResolving ? "Resolving…" : "Import") { importLink() }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isResolving)
                if manager.isResolving { Button(nativeLocalized("Cancel")) { manager.cancelImport() } }
            }
            Text(nativeLocalized("Collection files are stored separately from your game's Mods folder. Their generated profiles are protected; copy a profile to customize it."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = manager.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let status = manager.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HSplitView {
                List(selection: $manager.selectedID) {
                    ForEach(manager.collections) { collection in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(collection.name).font(.headline)
                            Text(collection.isLegacyImport ? "Imported installed copy · \(collection.completedCount) mods" : "Revision \(collection.revision) · \(collection.completedCount)/\(collection.selectedCount) files")
                                .font(.caption).foregroundStyle(.secondary)
                            if collection.hasUpdate { Text("Revision \(collection.latestRevision ?? collection.revision) available").font(.caption).foregroundStyle(Color.starfruitAccent) }
                        }.tag(collection.id)
                    }
                }
                .frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                if let collection = manager.collections.first(where: { $0.id == manager.selectedID }) {
                    CollectionDetailView(collection: collection, manager: manager, nexusClient: nexusClient,
                        chooseArchive: { entry in
                            targetEntry = (collection.id, entry.id)
                            importing = true
                        }, chooseAddon: {
                            targetEntry = nil
                            addonCollectionID = collection.id
                            importing = true
                        }, remove: { removing = collection })
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "square.stack.3d.up").font(.system(size: 32))
                        Text(nativeLocalized("Import or select a collection")).font(.headline)
                        Text(nativeLocalized("Review its optional files before installing.")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let id = manager.selectedID else { manager.error = "Select a collection before dropping archives."; return true }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                if !urls.isEmpty { manager.acceptManualArchives(urls, collectionID: id, nexusClient: nexusClient) }
            }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if let target = targetEntry { manager.installManualArchive(url, collectionID: target.collectionID, entryID: target.entryID, nexusClient: nexusClient) }
                    else if let id = addonCollectionID { manager.addAddonArchive(url, collectionID: id) }
                }
            case .failure(let error): manager.error = error.localizedDescription
            }
            targetEntry = nil
            addonCollectionID = nil
        }
        .confirmationDialog("Remove \(removing?.name ?? "collection")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(nativeLocalized("Remove Collection, Keep Mods")) {
                if let collection = removing { manager.remove(collection.id, deleteFiles: false) }
                removing = nil
            }
            if removing?.hasLegacyInstalledCopy != true {
                Button(nativeLocalized("Remove Collection and Files"), role: .destructive) {
                    if let collection = removing { manager.remove(collection.id, deleteFiles: true) }
                    removing = nil
                }
            }
            Button(nativeLocalized("Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(nativeLocalized("Keeping files turns its generated profile into an editable profile. Files used by other profiles cannot be deleted."))
        }
    }

    private func importLink() {
        manager.importCollection(link: link, nexusClient: nexusClient)
    }
}

private struct CollectionDetailView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let collection: NativeCollection
    @ObservedObject var manager: CollectionManager
    @ObservedObject var nexusClient: NexusClient
    var chooseArchive: (NativeCollectionEntry) -> Void
    var chooseAddon: () -> Void
    var remove: () -> Void
    @NativeState private var missingOnly = false
    @NativeState private var sortOrder = "Name"
    private var active: Bool { manager.activeIDs.contains(collection.id) }
    private var visibleEntries: [NativeCollectionEntry] {
        collection.entries.filter { !missingOnly || ($0.selected && $0.status != .installed) }.sorted {
            let left = sortOrder == "Status" ? $0.status.rawValue : sortOrder == "Version" ? $0.version ?? "" : $0.name
            let right = sortOrder == "Status" ? $1.status.rawValue : sortOrder == "Version" ? $1.version ?? "" : $1.name
            return left == right ? $0.id < $1.id : left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(collection.name).font(.title3.bold())
                    if let curator = collection.curator { Text("By \(curator)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(nativeLocalized("Nexus Page")) { NSWorkspace.shared.open(collection.pageURL) }
            }
            if let summary = collection.summary, !summary.isEmpty { Text(summary).font(.caption).lineLimit(3) }
            if let instructions = collection.instructions, !instructions.isEmpty {
                DisclosureGroup(nativeLocalized("Curator Instructions")) { Text(instructions).font(.caption).textSelection(.enabled) }
            }
            if let previous = collection.installedRevision, previous != collection.revision {
                Text(previous == 0 ? "Your imported installation remains playable while this revision is prepared. Its original revision was not recorded by the older app." : "Your revision \(previous) remains playable while revision \(collection.revision) is prepared. Existing config.json settings are preserved when the update completes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let changes = collection.updateSummary, collection.installedRevision != collection.revision {
                Text("Revision changes: \(changes.added) added · \(changes.replaced) replaced · \(changes.removed) removed · \(changes.unchanged) unchanged")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(nativeLocalized("Keep removed curator mods"), isOn: Binding(get: { collection.preserveRemovedMods }, set: { manager.setPreserveRemovedMods(collection.id, preserve: $0) }))
                    .font(.caption).disabled(active)
            }
            ProgressView(value: Double(collection.completedCount), total: Double(max(1, collection.selectedCount)))
            HStack {
                if collection.isLegacyImport {
                    Button(nativeLocalized("Use Installed Copy")) { manager.useImportedCollection(collection.id) }
                        .disabled(active)
                    Button(nativeLocalized("Review Latest Revision")) { manager.prepareUpdate(collection.id, nexusClient: nexusClient) }
                        .disabled(active || manager.isResolving || !nexusClient.hasApiKey)
                } else {
                    Button(active ? "Installing…" : collection.isComplete ? "Rebuild Profile" : "Install / Resume") { manager.install(collection.id, nexusClient: nexusClient) }
                        .disabled(active || !nexusClient.hasApiKey)
                }
                if active { Button(nativeLocalized("Cancel")) { manager.cancel(collection.id) } }
                if collection.hasUpdate {
                    Button(nativeLocalized("Review Update")) { manager.prepareUpdate(collection.id, nexusClient: nexusClient) }
                        .disabled(active || manager.isResolving)
                }
                Spacer()
                Button(nativeLocalized("Add-on…"), action: chooseAddon).disabled(active || collection.installedRevision == nil)
                Button(nativeLocalized("Remove…"), role: .destructive, action: remove).disabled(active)
            }
            if !nexusClient.hasApiKey { Text(nativeLocalized("Connect your Nexus API key in Settings to resolve download links.")).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Toggle(nativeLocalized("Missing only"), isOn: $missingOnly)
                Picker(nativeLocalized("Sort"), selection: $sortOrder) {
                    ForEach(["Name", "Version", "Status"], id: \.self) { Text(nativeLocalized($0)).tag($0) }
                }.frame(width: 150)
                Spacer()
                Button(nativeLocalized("Open Missing Pages")) {
                    for entry in collection.entries where entry.selected && entry.status != .installed {
                        if let url = entry.pageURL { NSWorkspace.shared.open(url) }
                    }
                }
            }.font(.caption)
            List(visibleEntries) { entry in
                CollectionEntryRow(entry: entry, active: active,
                    optionalSelection: Binding(get: { entry.selected }, set: { manager.setOptional(collectionID: collection.id, entryID: entry.id, selected: $0) }),
                    chooseArchive: { chooseArchive(entry) })
            }
            .listStyle(.inset)
        }
        .padding(.leading, 12)
        .frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CollectionEntryRow: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let entry: NativeCollectionEntry
    let active: Bool
    @Binding var optionalSelection: Bool
    var chooseArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if entry.optional { Toggle(nativeLocalized(""), isOn: $optionalSelection).labelsHidden().disabled(active) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text([entry.version, entry.optional ? "Optional" : "Required", entry.isPinned ? "Pinned file" : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.status.rawValue.capitalized).font(.caption)
                    .foregroundStyle(entry.status == .failed ? .red : entry.status == .installed ? .green : .secondary)
            }
            if let failure = entry.failure { Text(failure).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if entry.selected && entry.status != .installed {
                HStack {
                    if let url = entry.pageURL { Button(nativeLocalized("Open File Page")) { NSWorkspace.shared.open(url) } }
                    Button(nativeLocalized("Choose Downloaded Archive…"), action: chooseArchive).disabled(active)
                }.font(.caption)
            }
        }.padding(.vertical, 5)
    }
}
