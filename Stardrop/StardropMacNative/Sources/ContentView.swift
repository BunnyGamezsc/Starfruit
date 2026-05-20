import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selection: String? = "mods"
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var downloadManager: DownloadManager
    
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
                    Label("Installed Mods", systemImage: "square.grid.3x3.fill")
                }
                NavigationLink(value: "downloads") {
                    Label("Downloads", systemImage: "arrow.down.circle.fill")
                }
                NavigationLink(value: "settings") {
                    Label("Settings", systemImage: "gearshape.fill")
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
                } else if selection == "downloads" {
                    DownloadPanelView()
                        .starfruitPanel()
                        .padding()
                } else {
                    ModsListView()
                }
                
                statusFooter
            }
            .background(Color.starfruitBackground)
            .frame(minWidth: 700, minHeight: 500)
            .searchable(text: $modManager.searchText, prompt: "Search mods...")
        }
        .onAppear {
            let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
            let modsDir = useWine ? wineModsDir : nativeModsDir
            modManager.loadMods(smapiDir: smapiDir, customModsDir: modsDir)
        }
        .onDrop(of: [.zip], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url {
                        DispatchQueue.main.async {
                            let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
                            let modsDir = useWine ? wineModsDir : nativeModsDir
                            modManager.installMod(zipURL: url, smapiDir: smapiDir, customModsDir: modsDir)
                        }
                    }
                }
            }
            return true
        }
        .onOpenURL { url in
            if url.scheme?.lowercased() == "nxm" {
                handleNXMURL(url)
            }
        }
    }
    
    private var statusFooter: some View {
        HStack {
            Text(nexusClient.currentUser != nil ? "Nexus Mods: Connected (\(nexusClient.currentUser?.name ?? ""))" : "Nexus Mods: Not Connected")
            Spacer()
            Text("Successor to Stardrop")
                .foregroundColor(.starfruitAccent.opacity(0.7))
                .font(.caption.italic())
            Spacer()
            Text("Starfruit Native v1.0")
        }
        .font(.caption)
        .padding(8)
        .background(Color.starfruitSecondary.opacity(0.2))
        .foregroundColor(.starfruitBorder)
        .overlay(Rectangle().frame(height: 1).foregroundColor(.starfruitBorder), alignment: .top)
    }

    func handleNXMURL(_ url: URL) {
        modManager.handleNXMURL(url, nexusClient: nexusClient, downloadManager: downloadManager) {
            self.selection = "downloads"
        }
    }
}

struct ModsListView: View {
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"
    @AppStorage("useWine") private var useWine = true
    
    @State private var isShowingNewProfileAlert = false
    @State private var newProfileName = ""

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
                        Label("New Profile...", systemImage: "plus")
                    }
                    
                    if modManager.profiles.count > 1 {
                        Button(role: .destructive, action: {
                            if let id = modManager.selectedProfileID {
                                modManager.deleteProfile(id: id)
                            }
                        }) {
                            Label("Delete Current Profile", systemImage: "trash")
                        }
                    }
                } label: {
                    HStack {
                        Text("Profile: ")
                        Text(modManager.profiles.first(where: { $0.id == modManager.selectedProfileID })?.name ?? "None")
                            .foregroundColor(.starfruitAccent)
                            .bold()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                    }
                }
                .menuStyle(.borderlessButton)
                
                Spacer()
                
                HStack(spacing: 15) {
                    Text("Enabled Mods: \(modManager.mods.filter { modManager.isModEnabled(modID: $0.id) }.count)")
                    Text("Total Mods: \(modManager.mods.count)")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 10)

            HStack {
                playStopButton
                
                Button(action: {
                    Task {
                        await modManager.checkAllUpdates(nexusClient: nexusClient)
                    }
                }) {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .buttonStyle(StarfruitButtonStyle())
                .disabled(nexusClient.currentUser == nil)
            }
            .padding()
            
            // Mod List Panel
            VStack {
                List {
                    Section(header: 
                        HStack {
                            Text("Mod Name").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Version").frame(width: 80, alignment: .center)
                            Text("Status").frame(width: 80, alignment: .trailing)
                        }
                        .font(.caption.bold())
                        .foregroundColor(.starfruitBorder)
                    ) {
                        ForEach(modManager.filteredMods) { mod in
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { modManager.isModEnabled(modID: mod.id) },
                                    set: { _ in modManager.toggleMod(modID: mod.id) }
                                ))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(mod.id == "SMAPI.ConsoleCommands" || mod.id == "SMAPI.SaveBackup")
                                
                                VStack(alignment: .leading) {
                                    Text(mod.manifest.Name)
                                        .font(.headline)
                                        .foregroundColor(mod.hasUpdate ? .starfruitAccent : .primary)
                                    Text("by \(mod.manifest.Author)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                let missingDeps = modManager.getMissingDependencies(for: mod)
                                let disabledDeps = modManager.getDisabledDependencies(for: mod)
                                
                                if !missingDeps.isEmpty || !disabledDeps.isEmpty {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                        .help("Dependencies: \( (missingDeps.map { $0 + " (missing)" } + disabledDeps.map { $0 + " (disabled)" }).joined(separator: ", ") )")
                                        .frame(width: 30)
                                }

                                Text(mod.manifest.Version)
                                    .font(.subheadline.monospacedDigit())
                                    .frame(width: 80, alignment: .center)

                                if mod.hasUpdate {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundColor(.starfruitAccent)
                                        .help("Update available on Nexus Mods")
                                        .frame(width: 80, alignment: .trailing)
                                } else {
                                    Color.clear.frame(width: 80)
                                }
                            }
                            .contextMenu {
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.selectFile(mod.folderPath, inFileViewerRootedAtPath: "")
                                }
                                Divider()
                                Button("Delete Mod", role: .destructive) {
                                    let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
                                    let modsDir = useWine ? wineModsDir : nativeModsDir
                                    modManager.deleteMod(modID: mod.id, smapiDir: smapiDir, customModsDir: modsDir)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .starfruitPanel()
            .padding()
        }
        .alert("New Profile", isPresented: $isShowingNewProfileAlert) {
            TextField("Profile Name", text: $newProfileName)
            Button("Cancel", role: .cancel) { newProfileName = "" }
            Button("Create") {
                if !newProfileName.isEmpty {
                    modManager.addProfile(name: newProfileName)
                    newProfileName = ""
                }
            }
        } message: {
            Text("Enter a name for the new profile.")
        }
    }

    @ViewBuilder
    private var playStopButton: some View {
        if modManager.isGameRunning {
            Button(action: {
                modManager.stopGame()
            }) {
                Label("Stop Stardew Valley", systemImage: "stop.fill")
            }
            .buttonStyle(StarfruitButtonStyle())
            .tint(.red)
        } else {
            Button(action: launchSMAPI) {
                Label("Play Stardew Valley", systemImage: "play.fill")
            }
            .buttonStyle(StarfruitButtonStyle())
        }
    }
    
    func launchSMAPI() {
        let smapiDir = useWine ? wineSmapiDir : nativeSmapiDir
        let modsDir = useWine ? wineModsDir : nativeModsDir
        let stagingPath = modManager.prepareProfileForLaunch(smapiDir: smapiDir, customModsDir: modsDir)
        DispatchQueue.global(qos: .userInitiated).async {
            SMAPILauncher.launch(smapiDir: smapiDir, winePrefix: winePrefix, wineBinary: wineBinaryPath, useWine: useWine, modsPath: stagingPath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                modManager.checkGameStatus()
            }
        }
    }
}

struct DownloadPanelView: View {
    @EnvironmentObject var downloadManager: DownloadManager
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.title2.bold())
                Spacer()
                Button(action: {
                    downloadManager.clearCompleted()
                }) {
                    Label("Clear Completed", systemImage: "trash")
                }
                .buttonStyle(StarfruitButtonStyle())
                .disabled(downloadManager.activeDownloads.filter { $0.isCompleted || $0.error != nil }.isEmpty)
            }
            .padding()
            .background(Color.starfruitBackground)
            
            if downloadManager.activeDownloads.isEmpty {
                Spacer()
                Text("No active downloads")
                    .foregroundColor(.secondary)
                    .font(.headline)
                Spacer()
            } else {
                List(downloadManager.activeDownloads) { task in
                    DownloadRowView(task: task)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
    }
}

struct DownloadRowView: View {
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
                
                if let error = task.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                } else if task.isCompleted {
                    Text("Download and extraction complete")
                        .font(.caption)
                        .foregroundColor(.green)
                } else if task.isExtracting {
                    Text("Extracting...")
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
        }
        .padding(12)
        .background(Color.starfruitSecondary.opacity(0.5))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorForTask.opacity(0.3), lineWidth: 1)
        )
    }
    
    var iconForTask: String {
        if task.error != nil { return "exclamationmark.triangle.fill" }
        if task.isCompleted { return "checkmark.circle.fill" }
        if task.isExtracting { return "doc.zipper" }
        return "arrow.down.circle.fill"
    }
    
    var colorForTask: Color {
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
