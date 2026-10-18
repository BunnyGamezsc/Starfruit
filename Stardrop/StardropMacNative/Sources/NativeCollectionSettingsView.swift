import SwiftUI
import AppKit

struct NativeCollectionSettingsView: View {
    @ObservedObject var manager: CollectionManager
    var isGameActive: Bool = false
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @NativeState private var isMoving = false
    @NativeState private var errorMessage: String?

    var body: some View {
        Section(header: Text(nativeLocalized("Collection Storage")).font(.headline).foregroundColor(.starfruitBorder)) {
            Text(manager.storage.root.path).font(.caption).textSelection(.enabled)
            HStack {
                Button(nativeLocalized("Choose Collection Folder…"), action: chooseFolder)
                    .disabled(isMoving || isGameActive || manager.isResolving || !manager.activeIDs.isEmpty)
                if isMoving { ProgressView().controlSize(.small) }
            }
            Text(nativeLocalized("Choose an empty folder outside the game's Mods directory. Existing collections move with their records and revisions."))
                .font(.caption).foregroundColor(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundColor(.red) }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = nativeLocalized("Choose an empty collection folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isMoving = true
        Task {
            defer { isMoving = false }
            do { try await manager.changeStorageRoot(to: url); errorMessage = nil }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
