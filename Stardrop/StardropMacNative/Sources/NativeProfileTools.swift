import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NativeModNotesEditor: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let modName: String
    let onSave: (String) -> Void
    @NativeState var note: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Notes for \(modName)").font(.title2.bold())
            Text(nativeLocalized("Notes belong to the current profile.")).foregroundColor(.secondary)
            TextEditor(text: $note)
                .font(.body)
                .border(Color.secondary.opacity(0.3))
                .frame(minHeight: 180)
            HStack {
                Button(nativeLocalized("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(nativeLocalized("Save Note")) { onSave(note); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct NativeProfileExportOptions: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let profileName: String
    let onExport: (Bool, Bool, Bool) -> Void
    @NativeState private var includeNotes = true
    @NativeState private var includeDisabledMods = false
    @NativeState private var includeModConfigs = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export \(profileName)").font(.title2.bold())
            Toggle(nativeLocalized("Include profile notes"), isOn: $includeNotes)
            Toggle(nativeLocalized("Include disabled mods in the mod list"), isOn: $includeDisabledMods)
            Toggle(nativeLocalized("Include mod configurations"), isOn: $includeModConfigs)
            Text(nativeLocalized("The JSON file lists mods and their sources. Mod files are downloaded separately."))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button(nativeLocalized("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(nativeLocalized("Export…")) {
                    onExport(includeNotes, includeDisabledMods, includeModConfigs)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct MissingProfileModsView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @EnvironmentObject private var modManager: ModManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useWine") private var useWine = true
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @NativeState private var installStatus: String?
    @NativeState private var installError: String?

    private var missing: [SharedProfileMod] { modManager.currentProfile?.missingMods ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(nativeLocalized("Missing Profile Mods")).font(.title2.bold())
            Text(nativeLocalized("These mods are saved in your profile. Download their files, then import or drop ZIP archives here."))
                .foregroundColor(.secondary)
            if missing.isEmpty {
                Label(nativeLocalized("All requested mods are installed."), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).padding()
            } else {
                List(missing, id: \.uniqueID) { mod in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mod.name).font(.headline)
                            Text("\(mod.uniqueID) · \(mod.version)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if let url = sourceURL(for: mod) {
                            Link(nativeLocalized("Download"), destination: url)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 220)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    let profileID = modManager.selectedProfileID
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in
                            guard let url else { return }
                            Task { @MainActor in install(url, profileID: profileID) }
                        }
                    }
                    return !providers.isEmpty
                }
            }
            if let installStatus { Text(installStatus).font(.caption).foregroundColor(.secondary) }
            HStack {
                Button(nativeLocalized("Import ZIP Archives…")) { chooseArchives() }
                Spacer()
                Text("\(missing.count) missing").foregroundColor(.secondary)
                Button(nativeLocalized("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 420)
        .alert(nativeLocalized("Archive Import Failed"), isPresented: Binding(get: { installError != nil }, set: { if !$0 { installError = nil } })) {
            Button(nativeLocalized("OK"), role: .cancel) { installError = nil }
        } message: { Text(installError ?? "") }
    }

    private func sourceURL(for mod: SharedProfileMod) -> URL? {
        for key in mod.updateKeys {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "nexus", let id = Int(parts[1]), id > 0 {
                return URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(id)")
            }
            if parts[0].lowercased() == "github" {
                let repository = parts[1].split(separator: "/")
                if repository.count == 2,
                   repository.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) }) {
                    return URL(string: "https://github.com/\(repository[0])/\(repository[1])/releases")
                }
            }
        }
        return nil
    }

    private func chooseArchives() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = NativeArchiveInstaller.supportedExtensions.sorted().compactMap {
            UTType(filenameExtension: $0, conformingTo: .archive)
        }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let profileID = modManager.selectedProfileID
        for url in panel.urls { install(url, profileID: profileID) }
    }

    private func install(_ url: URL, profileID: UUID?) {
        guard url.isFileURL, NativeArchiveInstaller.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            installError = "Choose a supported mod archive."
            return
        }
        installStatus = "Installing \(url.lastPathComponent)…"
        let manager = modManager
        let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
        let modsDir = useWine ? wineModsDir : nativeModsDir
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try manager.installMod(zipURL: url, smapiDir: smapiDir, customModsDir: modsDir,
                                           autoEnableInProfileID: profileID)
                }.value
                installStatus = "Imported \(url.lastPathComponent)."
            } catch {
                installStatus = nil
                installError = error.localizedDescription
            }
        }
    }
}
