import SwiftUI

struct NativeModTrashConfirmation: View {
    let mod: ModEntry
    @EnvironmentObject private var modManager: ModManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Move \(mod.manifest.Name) to Trash?", systemImage: "trash")
                .font(.headline)
            Text(nativeLocalized("The mod's folder, including its config, will be moved to the macOS Trash."))
            Text(nativeLocalized("Profiles using this copy"))
                .font(.subheadline.bold())
            let profiles = modManager.profilesUsingMod(mod)
            if profiles.isEmpty {
                Text(nativeLocalized("No profiles currently enable this copy."))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profiles) { profile in
                            Label(profile.name, systemImage: "person.crop.rectangle")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                Text(nativeLocalized("These profiles will no longer have this mod available until it is restored."))
            }
            Text(nativeLocalized("Profile selections and notes are kept. Use Undo in Starfruit during this session, or recover the folder from Trash in Finder."))
                .font(.caption)
                .foregroundColor(.secondary)
            if modManager.isGameRunning || modManager.isLaunching {
                Text(nativeLocalized("Stop the game before moving mods to Trash."))
                    .foregroundColor(.orange)
            }
            HStack {
                Spacer()
                Button(nativeLocalized("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(nativeLocalized("Move to Trash"), role: .destructive) {
                    modManager.trashMod(mod)
                    dismiss()
                }
                .disabled(!modManager.canTrashMod(mod))
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

struct NativeModTrashNotice: View {
    @EnvironmentObject private var modManager: ModManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item = modManager.trashedMods.last {
                HStack {
                    Label("Moved \(item.name) to Trash", systemImage: "trash")
                        .lineLimit(2)
                    Spacer()
                    Button(nativeLocalized("Undo")) { modManager.undoModTrash() }
                        .disabled(modManager.isGameRunning || modManager.isLaunching)
                        .help(nativeLocalized("Restore the most recently trashed mod to its original folder. Stop the game before restoring mods."))
                }
            }
            if let error = modManager.modTrashError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button(nativeLocalized("Dismiss")) { modManager.modTrashError = nil }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal)
    }
}
