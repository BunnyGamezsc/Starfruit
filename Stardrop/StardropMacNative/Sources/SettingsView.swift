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
                                let success = await nexusClient.validate(key: tempAPIKey)
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
            }
            .padding()
        }
        .background(Color.starfruitBackground)
        .navigationTitle("Settings")
    }
    
    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @State private var tempAPIKey = ""
    @State private var isValidating = false
}
