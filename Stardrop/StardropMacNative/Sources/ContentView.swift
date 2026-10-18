import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @NativeState private var selection: String? = "mods"
    @NativeState private var isShowingOnboarding = false
    @NativeState private var downloadsSearchQuery: String = ""
    @NativeState private var archiveImportError: String?
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var acManager: AnimationCancelManager
    @EnvironmentObject var autoclickerManager: AutoclickerManager

    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"
    @AppStorage("useWine") private var useWine = true

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: "mods") {
                    Label(nativeLocalized("Installed Mods"), systemImage: "square.grid.3x3.fill")
                }
                NavigationLink(value: "collections") {
                    Label(nativeLocalized("Collections"), systemImage: "square.stack.3d.up.fill")
                }
                NavigationLink(value: "downloads") {
                    Label(nativeLocalized("Downloads"), systemImage: "arrow.down.circle.fill")
                }
                NavigationLink(value: "settings") {
                    Label(nativeLocalized("Settings"), systemImage: "gearshape.fill")
                }
            }
            .listStyle(.sidebar)
            .background(Color.starfruitBackground.opacity(0.5))
        } detail: {
            VStack(spacing: 0) {
                if selection == "settings" {
                    SettingsView()
                        .starfruitPanel()
                        .padding()
                } else if selection == "collections" {
                    CollectionsView()
                } else if selection == "downloads" {
                    DownloadPanelView(searchQuery: $downloadsSearchQuery)
                        .starfruitPanel()
                        .padding()
                } else {
                    ModsListView()
                }

                statusFooter
            }
            .background(Color.starfruitBackground)
            .frame(minWidth: 700, minHeight: 500)
            .searchable(text: Binding(get: {
                selection == "downloads" ? downloadsSearchQuery : modManager.searchText
            }, set: { new in
                if selection == "downloads" { downloadsSearchQuery = new } else { modManager.searchText = new }
            }), prompt: "Search mods...")
        }
        .onAppear {
            let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
            let modsDir = useWine ? wineModsDir : nativeModsDir
            modManager.loadMods(smapiDir: smapiDir, customModsDir: modsDir)
            modManager.collectionManager.nexusConnectionChanged(
                isConnected: nexusClient.hasApiKey && nexusClient.currentUser != nil, nexusClient: nexusClient)
            acManager.onAppear()
            autoclickerManager.onAppear()
            isShowingOnboarding = !onboardingCompleted
        }
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingView(isPresented: $isShowingOnboarding, selection: $selection)
                .environmentObject(nexusClient)
                .environmentObject(acManager)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard selection != "collections" else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        Task { @MainActor in installDroppedArchive(url) }
                    }
                }
            }
            return true
        }
        .alert(nativeLocalized("Archive Import Failed"), isPresented: Binding(get: { archiveImportError != nil }, set: { if !$0 { archiveImportError = nil } })) {
            Button(nativeLocalized("OK"), role: .cancel) { archiveImportError = nil }
        } message: { Text(archiveImportError ?? "") }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "nxm" {
                handleNXMURL(url)
            }
        }
        .onChange(of: nexusClient.hasApiKey && nexusClient.currentUser != nil) { connected in
            modManager.collectionManager.nexusConnectionChanged(isConnected: connected, nexusClient: nexusClient)
        }
    }

    @MainActor
    private func installDroppedArchive(_ url: URL) {
        guard url.isFileURL, NativeArchiveInstaller.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            archiveImportError = "Choose a supported mod archive (ZIP, 7z, RAR, TAR, GZ, BZ2 or XZ)."
            return
        }
        let manager = modManager
        let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
        let modsDir = useWine ? wineModsDir : nativeModsDir
        let targetProfileID = modManager.currentProfile?.isProtected == false ? modManager.selectedProfileID : nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try manager.installMod(zipURL: url, smapiDir: smapiDir, customModsDir: modsDir,
                                           autoEnableInProfileID: targetProfileID)
                }.value
            } catch {
                archiveImportError = error.localizedDescription
            }
        }
    }

    private var statusFooter: some View {
        HStack {
            Text(nexusClient.currentUser != nil ? "Nexus Mods: Connected (\(nexusClient.currentUser?.name ?? ""))" : "Nexus Mods: Not Connected")
            Spacer()
            Text(nativeLocalized("Successor to Stardrop"))
                .foregroundColor(.starfruitAccent.opacity(0.7))
                .font(.caption.italic())
            Spacer()
            // Animation cancel status indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(acManager.isEngineRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(acManager.isEngineRunning ? "AC Active" : (acManager.isEnabled ? "AC Standby" : "AC Off"))
            }
            .help(acManager.isEngineRunning ? "Animation Canceling is active (Stardew Valley focused)" :
                  acManager.isEnabled ? "Animation Canceling enabled – waiting for Stardew Valley focus" :
                  "Animation Canceling is disabled")
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(autoclickerManager.isClicking ? Color.starfruitAccent : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(autoclickerManager.isClicking ? "Auto Click Active" : (autoclickerManager.isEnabled ? "Auto Click Armed" : "Auto Click Off"))
                // toggle button
                Button(action: {
                    let new = !autoclickerManager.isEnabled
                    Task { @MainActor in
                        autoclickerManager.isEnabled = new
                    }
                }) {
                    Image(systemName: autoclickerManager.isEnabled ? "power.circle.fill" : "power.circle")
                        .foregroundColor(autoclickerManager.isEnabled ? Color.starfruitAccent : .secondary)
                }
                .buttonStyle(.plain)
            }
            .help(autoclickerStatusText)
            Spacer()
            Text(nativeLocalized("Starfruit Native v1.0"))
        }
        .font(.caption)
        .padding(8)
        .background(Color.starfruitSecondary.opacity(0.2))
        .foregroundColor(.starfruitBorder)
        .overlay(Rectangle().frame(height: 1).foregroundColor(.starfruitBorder), alignment: .top)
    }

    private var autoclickerStatusText: String {
        if !autoclickerManager.hasAccessibility {
            return "Autoclicker needs Accessibility permission before it can run."
        }
        if autoclickerManager.isClicking {
            return "Autoclicker is clicking in Stardew Valley."
        }
        if autoclickerManager.isEnabled {
            return "Press \(autoclickerManager.toggleKeyDescription) while Stardew Valley is focused to start or stop clicking."
        }
        return "Autoclicker is off. Turn it on here or in Settings."
    }

    func handleNXMURL(_ url: URL) {
        modManager.handleNXMURL(url, nexusClient: nexusClient, downloadManager: downloadManager) {
            self.selection = url.pathComponents.contains(where: { $0 == "collection" || $0 == "collections" }) ? "collections" : "downloads"
        }
    }
}

struct ModsListView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var acManager: AnimationCancelManager
    @EnvironmentObject var autoclickerManager: AutoclickerManager
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"
    @AppStorage("useWine") private var useWine = true

    @NativeState private var isShowingNewProfileAlert = false
    @NativeState private var newProfileName = ""
    @NativeState private var isShowingPresetAlert = false
    @NativeState private var newPresetName = ""
    @NativeState private var profileToolStatus: String?
    @AppStorage("nativeModColumns") private var storedColumns = ""
    @NativeState private var isShowingColumns = false
    @NativeState private var isShowingMissingMods = false
    @NativeState private var isShowingExportOptions = false
    @NativeState private var isShowingRenameProfile = false
    @NativeState private var renamedProfileName = ""
    @NativeState private var notesMod: ModEntry?
    @NativeState private var changelogMod: ModEntry?
    @NativeState private var showUpdatesOnly = false

    var body: some View {
        VStack {
            // Header info
            HStack {
                Menu {
                    ForEach(modManager.profiles) { profile in
                        Button(action: {
                            modManager.selectedProfileID = profile.id
                        }) {
                            HStack {
                                Text(profile.name)
                                if profile.id == modManager.selectedProfileID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }

                    Divider()

                    Button(action: {
                        isShowingNewProfileAlert = true
                    }) {
                        Label(nativeLocalized("New Profile..."), systemImage: "plus")
                    }

                    if modManager.profiles.count > 1 && !(modManager.currentProfile?.isProtected ?? false) {
                        Button(role: .destructive, action: {
                            if let id = modManager.selectedProfileID {
                                modManager.deleteProfile(id: id)
                            }
                        }) {
                            Label(nativeLocalized("Delete Current Profile"), systemImage: "trash")
                        }
                    }
                } label: {
                    HStack {
                        Text(nativeLocalized("Profile: "))
                        Text(modManager.profiles.first(where: { $0.id == modManager.selectedProfileID })?.name ?? "None")
                            .foregroundColor(.starfruitAccent)
                            .bold()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button {
                        isShowingExportOptions = true
                    } label: {
                        Label(nativeLocalized("Export Profile..."), systemImage: "square.and.arrow.up")
                    }

                    Button {
                        importSharedProfile()
                    } label: {
                        Label(nativeLocalized("Import Profile..."), systemImage: "square.and.arrow.down")
                    }

                    Button(nativeLocalized("Rename Profile…")) {
                        renamedProfileName = modManager.currentProfile?.name ?? ""
                        isShowingRenameProfile = true
                    }
                    .disabled(modManager.currentProfile?.isProtected ?? false)
                    Button(nativeLocalized("Copy Profile")) { modManager.copyCurrentProfile() }
                    if !(modManager.currentProfile?.missingMods.isEmpty ?? true) {
                        Button(nativeLocalized("Show Missing Mods…")) { isShowingMissingMods = true }
                    }

                    Divider()

                    Button {
                        isShowingPresetAlert = true
                    } label: {
                        Label(nativeLocalized("Save Current as Preset..."), systemImage: "bookmark")
                    }

                    if !modManager.presets.isEmpty {
                        Menu(nativeLocalized("Apply Preset")) {
                            ForEach(modManager.presets) { preset in
                                Button(preset.name) {
                                    modManager.applyPreset(preset)
                                }
                                .disabled(modManager.currentProfile?.isProtected ?? false)
                            }
                        }

                        Menu(nativeLocalized("Delete Preset")) {
                            ForEach(modManager.presets) { preset in
                                Button(preset.name, role: .destructive) {
                                    modManager.deletePreset(preset)
                                }
                            }
                        }
                    }
                } label: {
                    Label(nativeLocalized("Profile Tools"), systemImage: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)

                Spacer()

                HStack(spacing: 15) {
                    profileHealthBadge
                    Text("Enabled Mods: \(modManager.mods.filter { modManager.isModEnabled(modID: $0.id) }.count)")
                    Text("Total Mods: \(modManager.mods.count)")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            commandBar

            if let updateCheckStatus = modManager.updateCheckStatus {
                Text(updateCheckStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            if let profileToolStatus {
                Text(profileToolStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            if modManager.currentProfile?.isProtected ?? false {
                Text(nativeLocalized("This collection profile is protected. Copy the profile to customize its mods and notes."))
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal)
            }
            listControls
            modListPanel
        }
        .sheet(item: $notesMod) { mod in
            NativeModNotesEditor(modName: mod.manifest.Name, onSave: { note in
                modManager.setModNote(modID: mod.id, note: note)
            }, note: modManager.currentProfile?.modNotes[mod.id] ?? "")
        }
        .sheet(item: $changelogMod) { mod in
            if let modID = nexusModID(for: mod) {
                ChangelogView(modName: mod.manifest.Name, modID: modID)
                    .environmentObject(nexusClient)
            }
        }
        .sheet(isPresented: $isShowingColumns) {
            NativeModColumnsEditor(storedPreferences: $storedColumns)
        }
        .sheet(isPresented: $isShowingMissingMods) {
            MissingProfileModsView().environmentObject(modManager)
        }
        .sheet(isPresented: $isShowingExportOptions) {
            NativeProfileExportOptions(profileName: modManager.currentProfile?.name ?? "Profile") { includeNotes, includeDisabled, includeConfigs in
                exportCurrentProfile(includeNotes: includeNotes, includeDisabledMods: includeDisabled, includeModConfigs: includeConfigs)
            }
        }
        .alert(nativeLocalized("Rename Profile"), isPresented: $isShowingRenameProfile) {
            TextField("Profile Name", text: $renamedProfileName)
            Button(nativeLocalized("Cancel"), role: .cancel) { }
            Button(nativeLocalized("Rename")) {
                let name = renamedProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let id = modManager.selectedProfileID {
                    modManager.renameProfile(id: id, newName: name)
                }
            }
        }
        .alert(nativeLocalized("New Profile"), isPresented: $isShowingNewProfileAlert) {
            TextField("Profile Name", text: $newProfileName)
            Button(nativeLocalized("Cancel"), role: .cancel) { newProfileName = "" }
            Button(nativeLocalized("Create")) {
                if !newProfileName.isEmpty {
                    modManager.addProfile(name: newProfileName)
                    newProfileName = ""
                }
            }
        } message: {
            Text(nativeLocalized("Enter a name for the new profile."))
        }
        .alert(nativeLocalized("Save Preset"), isPresented: $isShowingPresetAlert) {
            TextField("Preset Name", text: $newPresetName)
            Button(nativeLocalized("Cancel"), role: .cancel) { newPresetName = "" }
            Button(nativeLocalized("Save")) {
                if !newPresetName.isEmpty {
                    modManager.saveCurrentProfileAsPreset(name: newPresetName)
                    profileToolStatus = "Saved preset: \(newPresetName)"
                    newPresetName = ""
                }
            }
        } message: {
            Text(nativeLocalized("Save this profile's enabled mods as a quick preset."))
        }
    }

    private var columns: [NativeModColumn] {
        NativeModListPreferences.decode(storedColumns).visibleColumns
    }

    private var displayedMods: [ModEntry] {
        modManager.filteredMods.filter { !showUpdatesOnly || ($0.hasUpdate && !isUpdateIgnored($0)) }
    }

    private var listControls: some View {
        HStack {
            Toggle(nativeLocalized("Updates only"), isOn: $showUpdatesOnly).toggleStyle(.checkbox)
            Menu(nativeLocalized("Visible Mods")) {
                Button(nativeLocalized("Enable Visible Mods")) {
                    modManager.setVisibleModsEnabled(true, modIDs: displayedMods.map(\.id))
                }
                Button(nativeLocalized("Disable Visible Mods")) {
                    modManager.setVisibleModsEnabled(false, modIDs: displayedMods.map(\.id))
                }
            }
            .disabled(displayedMods.isEmpty || (modManager.currentProfile?.isProtected ?? false))
            Button(nativeLocalized("Columns…")) { isShowingColumns = true }
            Spacer()
            if modManager.hasUnsavedProfileChanges {
                Text(nativeLocalized("Unsaved profile changes")).font(.caption).foregroundColor(.orange)
                Button(nativeLocalized("Save Profile Changes")) { modManager.savePendingProfiles() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            if let missing = modManager.currentProfile?.missingMods, !missing.isEmpty {
                Button("\(missing.count) Missing Mods…") { isShowingMissingMods = true }
            }
            Text("\(displayedMods.count) visible").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }

    private var modListPanel: some View {
        List {
            Section(header: modColumnHeaders) {
                ForEach(displayedMods) { mod in modRow(mod) }
            }
        }
        .listStyle(.inset)
        .starfruitPanel()
        .padding()
    }

    private var modColumnHeaders: some View {
        HStack(spacing: 10) {
            Text(nativeLocalized("")).frame(width: 18)
            ForEach(columns) { column in
                Text(nativeLocalized(column.title))
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column == .name ? .infinity : nil, alignment: .leading)
            }
        }
        .font(.caption.bold())
        .foregroundColor(.starfruitBorder)
    }

    private func modRow(_ mod: ModEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("Enable \(mod.manifest.Name)", isOn: Binding(
                get: { modManager.isModEnabled(modID: mod.id) },
                set: { _ in modManager.toggleMod(modID: mod.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(mod.id == "SMAPI.ConsoleCommands" || mod.id == "SMAPI.SaveBackup" || (modManager.currentProfile?.isProtected ?? false))
            ForEach(columns) { column in
                modCell(mod, column: column)
                    .frame(width: column.width, alignment: .leading)
                    .frame(maxWidth: column == .name ? .infinity : nil, alignment: .leading)
            }
        }
        .contextMenu {
            Button(nativeLocalized("Edit Profile Note…")) { notesMod = mod }
                .disabled(modManager.currentProfile?.isProtected ?? false)
            if nexusModID(for: mod) != nil {
                Button(nativeLocalized("View Changelog…")) { changelogMod = mod }
                if let id = nexusModID(for: mod), let url = URL(string: "https://www.nexusmods.com/stardewvalley/mods/\(id)") {
                    Link(nativeLocalized("Open Mod Page"), destination: url)
                }
            }
            if let version = modManager.getSuggestedVersion(for: mod), mod.hasUpdate || isUpdateIgnored(mod) {
                if let updateURL = mod.suggestedUpdateURL {
                    Link(nativeLocalized("Open Update"), destination: updateURL)
                }
                Button(isUpdateIgnored(mod) ? "Stop Ignoring \(version)" : "Ignore Update \(version)") {
                    modManager.ignoreUpdate(modID: mod.id, version: isUpdateIgnored(mod) ? nil : version)
                }
                .disabled(modManager.currentProfile?.isProtected ?? false)
            }
            Divider()
            Button(nativeLocalized("Reveal in Finder")) {
                NSWorkspace.shared.selectFile(mod.folderPath, inFileViewerRootedAtPath: "")
            }
            Button(nativeLocalized("Open Manifest")) { NSWorkspace.shared.open(URL(fileURLWithPath: mod.folderPath).appendingPathComponent("manifest.json")) }
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: mod.folderPath).appendingPathComponent("config.json").path) {
                Button(nativeLocalized("Open Config")) { NSWorkspace.shared.open(URL(fileURLWithPath: mod.folderPath).appendingPathComponent("config.json")) }
            }
            Divider()
            Button(nativeLocalized("Delete Mod"), role: .destructive) {
                modManager.deleteMod(modID: mod.id, smapiDir: useWine ? wineSmapiDir : nativeSmapiDir,
                                     customModsDir: useWine ? wineModsDir : nativeModsDir)
            }
            .disabled(modManager.currentProfile?.isProtected ?? false)
        }
    }

    @ViewBuilder
    private func modCell(_ mod: ModEntry, column: NativeModColumn) -> some View {
        switch column {
        case .name:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mod.manifest.Name).font(.headline)
                        .foregroundColor(mod.hasUpdate && !isUpdateIgnored(mod) ? .starfruitAccent : .primary)
                    compatibilityBadges(for: mod)
                }
                Text("by \(mod.manifest.Author)").font(.caption).foregroundColor(.secondary)
            }
        case .version:
            Text(mod.manifest.Version).font(.subheadline.monospacedDigit())
        case .status:
            modStatus(mod)
        case .notes:
            Button { notesMod = mod } label: {
                Text(modManager.currentProfile?.modNotes[mod.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Add note…")
                    .lineLimit(2).font(.caption)
            }.buttonStyle(.plain).foregroundColor(.secondary)
                .disabled(modManager.currentProfile?.isProtected ?? false)
        case .changelog:
            if nexusModID(for: mod) != nil {
                Button(nativeLocalized("View…")) { changelogMod = mod }.buttonStyle(.link)
            } else {
                Text(nativeLocalized("—")).foregroundColor(.secondary)
            }
        }
    }

    private func modStatus(_ mod: ModEntry) -> some View {
        let missing = modManager.getMissingDependencies(for: mod)
        let disabled = modManager.getDisabledDependencies(for: mod)
        return VStack(alignment: .leading, spacing: 3) {
            if !missing.isEmpty || !disabled.isEmpty {
                Label(nativeLocalized("Dependencies"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .help((missing.map { $0 + " (missing)" } + disabled.map { $0 + " (disabled)" }).joined(separator: ", "))
            }
            if mod.hasUpdate || isUpdateIgnored(mod) {
                Label(isUpdateIgnored(mod) ? "Ignored" : "Update", systemImage: isUpdateIgnored(mod) ? "eye.slash" : "arrow.up.circle.fill")
                    .foregroundColor(isUpdateIgnored(mod) ? Color.secondary : Color.starfruitAccent)
                    .help(modManager.getSuggestedVersion(for: mod).map { "Available version: \($0)" } ?? "Update available")
            }
        }.font(.caption)
    }

    private func isUpdateIgnored(_ mod: ModEntry) -> Bool {
        guard let version = modManager.getSuggestedVersion(for: mod) else { return false }
        guard let ignored = modManager.currentProfile?.ignoredUpdateVersions.first(where: {
            $0.key.caseInsensitiveCompare(mod.id) == .orderedSame
        })?.value else { return false }
        return ignored.caseInsensitiveCompare(version) == .orderedSame
    }

    private func nexusModID(for mod: ModEntry) -> Int? {
        for key in mod.manifest.UpdateKeys ?? [] {
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "nexus", let id = Int(parts[1]), id > 0 { return id }
        }
        return nil
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                playStopButton

                HStack(spacing: 8) {
                    Image(systemName: acManager.isEngineRunning ? "bolt.fill" : "bolt")
                        .foregroundColor(acStatusColor)
                    Text(nativeLocalized("Animation Cancel"))
                        .font(.headline)
                    Toggle(nativeLocalized(""), isOn: $acManager.isEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.16))
                .cornerRadius(8)
                .help(acManager.isEnabled ? "Animation Canceling is enabled" : "Animation Canceling is disabled")

                AutoclickerCommandToggle()
                    .environmentObject(autoclickerManager)

                Spacer()

                Button(action: {
                    Task {
                        await modManager.checkAllUpdates(nexusClient: nexusClient)
                    }
                }) {
                    if modManager.isCheckingUpdates {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(nativeLocalized("Checking"))
                        }
                    } else {
                        Label(nativeLocalized("Check for Updates"), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(StarfruitButtonStyle())
                .disabled(modManager.isCheckingUpdates)
                .help(modManager.updateCheckStatus ?? "Check for mod updates")
                .keyboardShortcut("r", modifiers: [.command])
            }

        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color.starfruitSecondary.opacity(0.18),
                    Color.black.opacity(0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.starfruitBorder.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(10)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var missingDependencyIssues: [(mod: ModEntry, deps: [String])] {
        modManager.mods.compactMap { mod in
            let deps = modManager.getMissingDependencies(for: mod)
            return deps.isEmpty ? nil : (mod, deps)
        }
    }

    private var disabledDependencyIssues: [(mod: ModEntry, deps: [String])] {
        modManager.mods.compactMap { mod in
            let deps = modManager.getDisabledDependencies(for: mod)
            return deps.isEmpty ? nil : (mod, deps)
        }
    }

    private var duplicateGroups: [(id: String, mods: [ModEntry])] {
        Dictionary(grouping: modManager.mods, by: { $0.id })
            .filter { $0.value.count > 1 }
            .map { (id: $0.key, mods: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private var profileIssueCount: Int {
        missingDependencyIssues.count + disabledDependencyIssues.count + duplicateGroups.count
    }

    private var profileHealthBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: profileIssueCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(profileIssueCount == 0 ? .green : .orange)
            Text(profileIssueCount == 0 ? "Healthy" : "\(profileIssueCount) issue\(profileIssueCount == 1 ? "" : "s")")
        }
        .help(profileHealthHelpText)
    }

    private var acStatusText: String {
        if !acManager.hasAccessibility {
            return "Animation Cancel needs Accessibility permission before it can run."
        }
        if acManager.isEngineRunning {
            return "Animation Cancel is active for Stardew Valley."
        }
        if acManager.isEnabled {
            return "Animation Cancel is ready and waiting for Stardew Valley focus."
        }
        return "Animation Cancel is off. Turn it on here or in Settings."
    }

    private var acStatusIcon: String {
        if !acManager.hasAccessibility { return "lock.trianglebadge.exclamationmark" }
        return acManager.isEngineRunning ? "bolt.fill" : "bolt"
    }

    private var acStatusColor: Color {
        if !acManager.hasAccessibility { return .orange }
        return acManager.isEngineRunning ? .green : .secondary
    }

    private var profileHealthHelpText: String {
        if profileIssueCount == 0 {
            return "No missing dependencies, disabled required dependencies, or duplicate mod IDs detected."
        }

        var lines: [String] = []
        lines += missingDependencyIssues.prefix(3).map { "\($0.mod.manifest.Name) is missing \($0.deps.joined(separator: ", "))" }
        lines += disabledDependencyIssues.prefix(3).map { "\($0.mod.manifest.Name) needs disabled dependency \($0.deps.joined(separator: ", "))" }
        lines += duplicateGroups.prefix(3).map { "Duplicate mod ID \($0.id) appears \($0.mods.count) times" }
        return lines.joined(separator: "\n")
    }

    private func compatibilityBadges(for mod: ModEntry) -> some View {
        HStack(spacing: 5) {
            ForEach(compatibilityTags(for: mod), id: \.title) { tag in
                Label(tag.title, systemImage: tag.icon)
                    .font(.caption2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tag.color.opacity(0.18))
                    .foregroundColor(tag.color)
                    .cornerRadius(4)
                    .help(tag.help)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func compatibilityTags(for mod: ModEntry) -> [CompatibilityTag] {
        var tags: [CompatibilityTag] = []
        if let loaderID = mod.manifest.ContentPackFor?.UniqueID, !loaderID.isEmpty {
            tags.append(CompatibilityTag(title: "Content Pack", icon: "shippingbox", color: .mint, help: "Loaded by \(loaderID). Content packs are usually safer to swap than code mods."))
        } else {
            tags.append(CompatibilityTag(title: "SMAPI Mod", icon: "hammer", color: .cyan, help: "Runs code through SMAPI. Check compatibility when Stardew or SMAPI updates."))
        }

        if mod.manifest.UpdateKeys?.contains(where: { $0.lowercased().hasPrefix("nexus:") }) == true {
            tags.append(CompatibilityTag(title: "Nexus", icon: "arrow.triangle.2.circlepath", color: .starfruitAccent, help: "Has a Nexus update key, so Starfruit can check for updates."))
        }

        let nameAndID = "\(mod.manifest.Name) \(mod.id)".lowercased()
        if nameAndID.contains("expanded") || nameAndID.contains("farm") || nameAndID.contains("json assets") || nameAndID.contains("spacecore") {
            tags.append(CompatibilityTag(title: "Save-Affecting", icon: "externaldrive.badge.exclamationmark", color: .orange, help: "Heuristic: this mod may affect save data or world content. Avoid removing mid-save without checking notes."))
        }
        if nameAndID.contains("multiplayer") || nameAndID.contains("split screen") {
            tags.append(CompatibilityTag(title: "Co-op", icon: "person.2", color: .green, help: "Heuristic: this mod mentions multiplayer or co-op behavior."))
        }
        return tags
    }

    private func exportCurrentProfile(includeNotes: Bool = true, includeDisabledMods: Bool = false, includeModConfigs: Bool = false) {
        guard let manifest = modManager.sharedProfileManifestForCurrentProfile(includeNotes: includeNotes, includeDisabledMods: includeDisabledMods, includeModConfigs: includeModConfigs) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(manifest.name)-StarfruitProfile.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: url)
                profileToolStatus = "Exported profile: \(manifest.name)"
            } catch {
                profileToolStatus = "Profile export failed: \(error.localizedDescription)"
            }
        }
    }

    private func importSharedProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try modManager.importSharedProfile(from: url)
                let count = modManager.currentProfile?.missingMods.count ?? 0
                profileToolStatus = count == 0 ? "Imported shared profile." : "Imported profile with \(count) missing mods."
                isShowingMissingMods = count > 0
            } catch {
                profileToolStatus = "Profile import failed: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var playStopButton: some View {
        if modManager.isGameRunning {
            Button(action: {
                modManager.stopGame()
            }) {
                Label(nativeLocalized("Stop Stardew Valley"), systemImage: "stop.fill")
            }
            .buttonStyle(StarfruitButtonStyle())
            .tint(.red)
        } else {
            if modManager.isLaunching {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(nativeLocalized("Launching…"))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(8)
            } else {
                Button(action: launchSMAPI) {
                    Label(nativeLocalized("Play Stardew Valley"), systemImage: "play.fill")
                }
                .buttonStyle(StarfruitButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }

    func launchSMAPI() {
        let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
        let modsDir = useWine ? wineModsDir : nativeModsDir
        guard let stagingPath = modManager.prepareProfileForLaunch(smapiDir: smapiDir, customModsDir: modsDir) else { return }
        // Start a transient launching state so the UI shows progress
        modManager.startLaunchTimeout()

        DispatchQueue.global(qos: .userInitiated).async {
            SMAPILauncher.launch(smapiDir: smapiDir, winePrefix: winePrefix, wineBinary: wineBinaryPath, useWine: useWine, modsPath: stagingPath)
            // Let the system settle then re-check actual running status
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                modManager.checkGameStatus()
            }
        }
    }
}

private struct CompatibilityTag {
    let title: String
    let icon: String
    let color: Color
    let help: String
}

private struct AutoclickerCommandToggle: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @EnvironmentObject var autoclickerManager: AutoclickerManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: autoclickerManager.isClicking ? "cursorarrow.click.2" : "cursorarrow.click")
                .foregroundColor(statusColor)
            Text(autoclickerManager.isClicking ? "Auto Click On" : "Auto Click")
                .font(.headline)
            Text(autoclickerManager.toggleKeyDescription)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.16))
        .cornerRadius(8)
        .help(statusText)
    }

    private var statusText: String {
        if !autoclickerManager.hasAccessibility {
            return "Autoclicker needs Accessibility permission before it can run."
        }
        if autoclickerManager.isClicking {
            return "Autoclicker is clicking in Stardew Valley."
        }
        if autoclickerManager.isEnabled {
            return "Press \(autoclickerManager.toggleKeyDescription) while Stardew Valley is focused to start or stop clicking."
        }
        return "Autoclicker is off. Turn it on here or in Settings."
    }

    private var statusColor: Color {
        if !autoclickerManager.hasAccessibility { return .orange }
        return autoclickerManager.isClicking ? .green : .secondary
    }
}

struct OnboardingView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @Binding var isPresented: Bool
    @Binding var selection: String?
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var acManager: AnimationCancelManager

    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @AppStorage("useWine") private var useWine = true
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nativeLocalized("Set Up Starfruit"))
                        .font(.largeTitle.bold())
                    Text(nativeLocalized("Get Stardew, Nexus, and Animation Cancel ready before your first launch."))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 14) {
                setupRow(
                    icon: useWine ? "wineglass" : "desktopcomputer",
                    title: "Launch mode",
                    status: useWine ? "Wine / CrossOver" : "Native macOS",
                    isReady: true
                )

                Picker(nativeLocalized("Run Game Via"), selection: $useWine) {
                    Text(nativeLocalized("Native macOS")).tag(false)
                    Text(nativeLocalized("Wine / CrossOver")).tag(true)
                }
                .pickerStyle(.segmented)

                if useWine {
                    TextField("Wine game directory", text: $wineSmapiDir)
                        .textFieldStyle(.roundedBorder)
                    TextField("Wine mods directory (optional)", text: $wineModsDir)
                        .textFieldStyle(.roundedBorder)
                    TextField("Wine prefix", text: $winePrefix)
                        .textFieldStyle(.roundedBorder)
                    TextField("Wine binary", text: $wineBinaryPath)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField("Native game directory", text: $nativeSmapiDir)
                        .textFieldStyle(.roundedBorder)
                    TextField("Native mods directory (optional)", text: $nativeModsDir)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .starfruitPanel()

            VStack(alignment: .leading, spacing: 12) {
                setupRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Nexus Mods",
                    status: nexusClient.currentUser != nil ? "Connected as \(nexusClient.currentUser?.name ?? "")" : "Not connected",
                    isReady: nexusClient.currentUser != nil
                )

                setupRow(
                    icon: "bolt.fill",
                    title: "Animation Cancel",
                    status: acManager.hasAccessibility ? "Accessibility permission granted" : "Needs Accessibility permission",
                    isReady: acManager.hasAccessibility
                )

                HStack {
                    Button(nativeLocalized("Open Settings")) {
                        selection = "settings"
                        isPresented = false
                    }
                    .buttonStyle(StarfruitButtonStyle())

                    if !acManager.hasAccessibility {
                        Button(nativeLocalized("Open Accessibility")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                }
            }
            .starfruitPanel()

            Spacer()

            HStack {
                Button(nativeLocalized("Skip for Now")) {
                    finish()
                }
                .buttonStyle(StarfruitButtonStyle())

                Spacer()

                Button(nativeLocalized("Finish Setup")) {
                    finish()
                }
                .buttonStyle(StarfruitButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 620, height: 680)
        .background(Color.starfruitBackground)
    }

    private func finish() {
        onboardingCompleted = true
        isPresented = false
    }

    private func setupRow(icon: String, title: String, status: String, isReady: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(isReady ? .green : .orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(isReady ? .green : .orange)
        }
    }
}

struct NexusSearchResult: Codable, Identifiable {
    var id: Int { mod_id }
    let name: String
    let mod_id: Int
    let game_id: Int?
    let author: String?
    let downloads: Int?
    let endorsements: Int?
    let summary: String?
    let url: String?
    let thumb_url: String?
}

struct NexusSearchResponse: Codable {
    let total: Int?
    let terms: [String]?
    let results: [NexusSearchResult]?
}

struct DownloadPanelView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @EnvironmentObject var downloadManager: DownloadManager
    @Binding var searchQuery: String
    @NativeState private var searchResults: [NexusSearchResult] = []
    @NativeState private var isSearching = false
    @NativeState private var searchError: String? = nil
    @NativeState private var hasSearched = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(nativeLocalized("Downloads"))
                    .font(.title2.bold())
                Spacer()
                Button(action: { downloadManager.clearCompleted() }) {
                    Label(nativeLocalized("Clear Completed"), systemImage: "trash")
                }
                .buttonStyle(StarfruitButtonStyle())
                .disabled(downloadManager.activeDownloads.filter { $0.isCompleted || $0.error != nil }.isEmpty)
            }
            .padding()
            .background(Color.starfruitBackground)

            Divider().background(Color.starfruitBorder.opacity(0.4))

            // Nexus Mod Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.starfruitBorder)
                TextField("Search Nexus Mods for Stardew Valley...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { performSearch() }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !searchQuery.isEmpty {
                    Button(action: {
                        searchQuery = ""
                        searchResults = []
                        hasSearched = false
                        searchError = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button(nativeLocalized("Search")) { performSearch() }
                    .buttonStyle(StarfruitButtonStyle())
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.starfruitSecondary.opacity(0.08))

            Divider().background(Color.starfruitBorder.opacity(0.4))

            // Content area
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Active downloads section
                    if !downloadManager.activeDownloads.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(nativeLocalized("Active Downloads"))
                                .font(.caption.bold())
                                .foregroundColor(.starfruitBorder)
                                .padding(.horizontal)
                                .padding(.top, 12)
                            ForEach(downloadManager.activeDownloads) { task in
                                DownloadRowView(task: task)
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                            }
                        }
                        Divider()
                            .background(Color.starfruitBorder.opacity(0.3))
                            .padding(.vertical, 8)
                    }

                    // Search results section
                    if let error = searchError {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.title2)
                                .foregroundColor(.orange)
                            Text(error)
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if hasSearched && searchResults.isEmpty && !isSearching {
                        VStack(spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text("No mods found for \"\(searchQuery)\"")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    } else if !searchResults.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(searchResults.count) result\(searchResults.count == 1 ? "" : "s") on Nexus Mods")
                                .font(.caption.bold())
                                .foregroundColor(.starfruitBorder)
                                .padding(.horizontal)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                            ForEach(searchResults) { result in
                                NexusSearchResultRow(result: result)
                            }
                        }
                    } else if !hasSearched && downloadManager.activeDownloads.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.to.line.circle")
                                .font(.system(size: 40))
                                .foregroundColor(.starfruitBorder.opacity(0.5))
                            Text(nativeLocalized("Search Nexus Mods above or click a\n\"Mod Manager Download\" button on Nexus."))
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                            Text(nativeLocalized("No API key required for search."))
                                .foregroundColor(.secondary.opacity(0.6))
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    }
                }
            }
        }
    }

    private func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        searchResults = []

        Task {
            do {
                // Nexus public search — no API key required
                var components = URLComponents(string: "https://search.nexusmods.com/mods")!
                components.queryItems = [
                    URLQueryItem(name: "terms", value: query),
                    URLQueryItem(name: "game_id", value: "1303"), // Stardew Valley game ID
                    URLQueryItem(name: "blocked_tags", value: ""),
                    URLQueryItem(name: "blocked_authors", value: ""),
                    URLQueryItem(name: "include_adult", value: "0")
                ]
                guard let url = components.url else { throw URLError(.badURL) }

                var request = URLRequest(url: url)
                request.setValue("Mozilla/5.0 Starfruit/1.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let decoded = try JSONDecoder().decode(NexusSearchResponse.self, from: data)
                await MainActor.run {
                    searchResults = decoded.results ?? []
                    hasSearched = true
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    searchError = "Search failed: \(error.localizedDescription)"
                    hasSearched = true
                    isSearching = false
                }
            }
        }
    }
}

struct NexusSearchResultRow: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    let result: NexusSearchResult

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let author = result.author {
                        Text("by \(author)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if let dl = result.downloads, dl > 0 {
                        Label("\(formatCount(dl))", systemImage: "arrow.down.circle")
                            .font(.caption2)
                            .foregroundColor(.starfruitBorder)
                    }
                    if let en = result.endorsements, en > 0 {
                        Label("\(formatCount(en))", systemImage: "hand.thumbsup")
                            .font(.caption2)
                            .foregroundColor(.starfruitAccent)
                    }
                }
                if let summary = result.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: openOnNexus) {
                Label(nativeLocalized("View"), systemImage: "safari")
            }
            .buttonStyle(StarfruitButtonStyle())
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.starfruitSecondary.opacity(0.06))
        .overlay(Divider().foregroundColor(Color.starfruitBorder.opacity(0.15)), alignment: .bottom)
    }

    private func openOnNexus() {
        let urlString = result.url
            ?? "https://www.nexusmods.com/stardewvalley/mods/\(result.mod_id)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

struct DownloadRowView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @EnvironmentObject private var downloadManager: DownloadManager
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconForTask)
                .font(.system(size: 24))
                .foregroundColor(colorForTask)
                .frame(width: 40, height: 40)
                .background(colorForTask.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(task.fileName)
                    .font(.headline)
                    .lineLimit(1)

                if let manualURL = task.manualDownloadURL {
                    HStack {
                        Text(task.error ?? "Requires Manual Download")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(manualURL)
                        }) {
                            Label(nativeLocalized("Download Manually"), systemImage: "safari")
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                } else if let error = task.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else if task.isCancelled {
                    Text(nativeLocalized("Download cancelled")).font(.caption).foregroundColor(.secondary)
                } else if task.isCompleted {
                    Text(nativeLocalized("Download and extraction complete"))
                        .font(.caption)
                        .foregroundColor(.green)
                } else if task.isExtracting {
                    Text(nativeLocalized("Extracting..."))
                        .font(.caption)
                        .foregroundColor(.starfruitAccent)
                } else {
                    ProgressView(value: task.progress)
                        .tint(.starfruitAccent)

                    HStack {
                        Text("\(formatBytes(task.downloadedBytes)) / \(formatBytes(task.totalBytes))")
                        Spacer()
                        if task.speedBytesPerSecond > 0 {
                            Text("\(formatBytes(Int64(task.speedBytesPerSecond)))/s • \(formatTime(task.etaSeconds)) left")
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
            }
            if !task.isCompleted && !task.isCancelled && !task.isExtracting && task.error == nil && task.manualDownloadURL == nil {
                Button(nativeLocalized("Cancel")) { downloadManager.cancelDownload(id: task.id) }
                    .help(nativeLocalized("Cancel this download"))
            }
        }
        .padding(12)
        .background(Color.starfruitSecondary.opacity(0.15))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorForTask.opacity(0.3), lineWidth: 1)
        )
    }

    var iconForTask: String {
        if task.isCancelled { return "xmark.circle" }
        if task.manualDownloadURL != nil { return "safari" }
        if task.error != nil { return "exclamationmark.triangle.fill" }
        if task.isCompleted { return "checkmark.circle.fill" }
        if task.isExtracting { return "doc.zipper" }
        return "arrow.down.circle.fill"
    }

    var colorForTask: Color {
        if task.isCancelled { return .secondary }
        if task.manualDownloadURL != nil { return .orange }
        if task.error != nil { return .red }
        if task.isCompleted { return .green }
        return .starfruitAccent
    }

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "--s" }
        if seconds < 60 {
            return "\(Int(seconds))s"
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m \(secs)s"
    }
}
