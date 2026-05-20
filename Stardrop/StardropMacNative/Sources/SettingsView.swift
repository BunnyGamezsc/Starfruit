import SwiftUI

struct SettingsView: View {
    @AppStorage("useWine") private var useWine = true
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Section(header: Text("Launch Mode").font(.headline).foregroundColor(.starfruitBorder)) {
                    Picker("Run Game Via", selection: $useWine) {
                        Text("Native macOS").tag(false)
                        Text("Wine / Crossover").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider().background(Color.starfruitBorder)

                if !useWine {
                    Section(header: Text("Native macOS Settings").font(.headline).foregroundColor(.starfruitBorder)) {
                        VStack(alignment: .leading) {
                            Text("Native Game Directory").font(.caption)
                            TextField("/Applications/Stardew Valley.app/Contents/MacOS", text: $nativeSmapiDir)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Native Mods Directory (Optional)").font(.caption)
                            TextField("Default is Mods subfolder", text: $nativeModsDir)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                } else {
                    Section(header: Text("Wine Settings").font(.headline).foregroundColor(.starfruitBorder)) {
                        VStack(alignment: .leading) {
                            Text("Wine Game Directory").font(.caption)
                            TextField("Path to Stardew Valley (Windows)", text: $wineSmapiDir)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Wine Mods Directory (Optional)").font(.caption)
                            TextField("Default is Mods subfolder", text: $wineModsDir)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Wine Prefix").font(.caption)
                            TextField("~/.wine", text: $winePrefix)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Wine Binary").font(.caption)
                            TextField("/opt/homebrew/bin/wine", text: $wineBinaryPath)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                
                Divider().background(Color.starfruitBorder)
                
                Section(header: Text("Appearance").font(.headline).foregroundColor(.starfruitBorder)) {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }
                
                Divider().background(Color.starfruitBorder)
                
                Section(header: Text("Nexus Mods").font(.headline).foregroundColor(.starfruitBorder)) {
                    if let user = nexusClient.currentUser {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Logged in as \(user.name)")
                                    .font(.headline)
                                Text(user.is_premium ? "Premium Account" : "Free Account")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Logout") {
                                nexusClient.logout()
                            }
                            .buttonStyle(StarfruitButtonStyle())
                        }
                    } else {
                        SecureField("Nexus API Key", text: $tempAPIKey)
                            .textFieldStyle(.roundedBorder)
                        
                        Button(action: {
                            Task {
                                isValidating = true
                                _ = await nexusClient.validate(key: tempAPIKey)
                                isValidating = false
                            }
                        }) {
                            if isValidating {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Connect to Nexus Mods")
                            }
                        }
                        .buttonStyle(StarfruitButtonStyle())
                        .disabled(tempAPIKey.isEmpty || isValidating)
                    }
                }
                
                Divider().background(Color.starfruitBorder)
                
                Section(header: Text("Data Migration").font(.headline).foregroundColor(.starfruitBorder)) {
                    Button(action: {
                        modManager.importOriginalProfiles()
                    }) {
                        Label("Import Profiles from Starfruit C#", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(StarfruitButtonStyle())
                    .help("Scans the original Starfruit app's data folder and imports your existing profiles.")
                }
                
                Divider().background(Color.starfruitBorder)
                
                Section(header: Text("Deep Link Debugger").font(.headline).foregroundColor(.starfruitBorder)) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Manually test an NXM link or view received links.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            TextField("Paste nxm:// link here...", text: $testURLText)
                                .textFieldStyle(.roundedBorder)
                            
                            Button("Test Link") {
                                if let url = URL(string: testURLText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    modManager.handleNXMURL(url, nexusClient: nexusClient, downloadManager: downloadManager)
                                } else {
                                    modManager.logDeepLink("Error: Invalid URL entered.")
                                }
                            }
                            .buttonStyle(StarfruitButtonStyle())
                            .disabled(testURLText.isEmpty)
                        }
                        
                        HStack {
                            Text("Received Link Logs").font(.subheadline).bold()
                            Spacer()
                            Button("Clear Logs") {
                                modManager.clearDeepLinkLogs()
                            }
                            .buttonStyle(StarfruitButtonStyle())
                            .disabled(modManager.deepLinkLogs.isEmpty)
                        }
                        
                        if modManager.deepLinkLogs.isEmpty {
                            Text("No deep links captured yet.")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .background(Color.black.opacity(0.2))
                                .cornerRadius(6)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    ForEach(modManager.deepLinkLogs, id: \.self) { log in
                                        Text(log)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(log.contains("Error:") ? .red : .primary)
                                            .padding(4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.black.opacity(log.contains("Error:") ? 0.3 : 0.15))
                                            .cornerRadius(4)
                                    }
                                }
                            }
                            .frame(height: 150)
                            .background(Color.black.opacity(0.1))
                            .cornerRadius(6)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color.starfruitBackground)
        .navigationTitle("Settings")
    }
    
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var downloadManager: DownloadManager
    @State private var tempAPIKey = ""
    @State private var testURLText = ""
    @State private var isValidating = false
}
