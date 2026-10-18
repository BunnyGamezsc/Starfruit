import SwiftUI

struct ChangelogView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let modName: String
    let modID: Int
    @EnvironmentObject private var nexusClient: NexusClient
    @Environment(\.dismiss) private var dismiss
    @NativeState private var changelogs: [NexusChangelog] = []
    @NativeState private var isLoading = true
    @NativeState private var errorMessage: String?
    @NativeState private var requestID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Changelog: \(modName)").font(.title2.bold())
                Spacer()
                Button(nativeLocalized("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if isLoading {
                ProgressView("Loading changelog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Text(errorMessage).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button(nativeLocalized("Retry")) { requestID += 1 }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if changelogs.isEmpty {
                Text(nativeLocalized("No changelog is available for this mod."))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(changelogs.enumerated()), id: \.offset) { _, changelog in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(changelog.version).font(.headline)
                                ForEach(Array(changelog.entries.enumerated()), id: \.offset) { _, entry in
                                    Text("• \(entry)").textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }
            }
            if let url = URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(modID)?tab=logs") {
                Link(nativeLocalized("View on Nexus Mods"), destination: url)
            }
        }
        .padding(24)
        .frame(width: 640, height: 480)
        .task(id: requestID) { await load() }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            let result = try await nexusClient.fetchChangelogs(modID: modID)
            guard !Task.isCancelled else { return }
            changelogs = result
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
