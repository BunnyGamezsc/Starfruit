import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @AppStorage("useWine") private var useWine = true
    @AppStorage("nativeSmapiDir") private var nativeSmapiDir = "/Applications/Stardew Valley.app/Contents/MacOS"
    @AppStorage("nativeModsDir") private var nativeModsDir = ""
    @AppStorage("wineSmapiDir") private var wineSmapiDir = ""
    @AppStorage("wineModsDir") private var wineModsDir = ""
    @AppStorage("winePrefix") private var winePrefix = "~/.wine"
    @AppStorage("wineBinaryPath") private var wineBinaryPath = "/opt/homebrew/bin/wine"
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("nativeLanguage") private var nativeLanguage = "en"
    @AppStorage("alwaysAskForCollectionInstallTarget") private var alwaysAskForCollectionInstallTarget = true

    @EnvironmentObject var modManager: ModManager
    @EnvironmentObject var nexusClient: NexusClient
    @EnvironmentObject var downloadManager: DownloadManager
    @EnvironmentObject var animationCancelManager: AnimationCancelManager
    @EnvironmentObject var autoclickerManager: AutoclickerManager
    @NativeState private var tempAPIKey = ""
    @NativeState private var testURLText = ""
    @NativeState private var isValidating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                launchModeSection

                Divider().background(Color.starfruitBorder)

                if !useWine {
                    nativeSettingsSection
                } else {
                    wineSettingsSection
                }

                Divider().background(Color.starfruitBorder)

                appearanceSection
                NativeThemeSettingsView()

                Divider().background(Color.starfruitBorder)
                profileSettingsSection
                NativeCollectionSettingsView(manager: modManager.collectionManager,
                                             isGameActive: modManager.isGameRunning || modManager.isLaunching)

                Divider().background(Color.starfruitBorder)
                languageSection

                Divider().background(Color.starfruitBorder)

                animationCancelSection

                Divider().background(Color.starfruitBorder)

                autoclickerSection

                Divider().background(Color.starfruitBorder)

                nexusModsSection

                Divider().background(Color.starfruitBorder)
                NexusAssociationSettingsView()

                Divider().background(Color.starfruitBorder)

                dataMigrationSection

                Divider().background(Color.starfruitBorder)

                deepLinkDebuggerSection
            }
            .padding()
        }
        .background(Color.starfruitBackground)
        .navigationTitle(nativeLocalized("Settings"))
        .onChange(of: nativeLanguage) { language in
            NativeLocalization.shared.language = language
        }
        .onAppear { NativeLocalization.shared.language = nativeLanguage }
    }

    private var profileSettingsSection: some View {
        Section(header: Text(nativeLocalized("Profile Saving")).font(.headline).foregroundColor(.starfruitBorder)) {
            Toggle(nativeLocalized("Automatically Save Profile Changes"), isOn: $modManager.automaticallySaveProfileChanges)
            Toggle(nativeLocalized("Ask where to install extra collection mods"), isOn: $alwaysAskForCollectionInstallTarget)
            Toggle(nativeLocalized("Suppress SMAPI update checks for pinned collection mods"), isOn: $modManager.collectionsSkipSMAPIUpdateCheck)
            Text(nativeLocalized("When disabled, use Save Profile Changes in the mod list to keep enabled mods and notes for the next session."))
                .font(.caption).foregroundColor(.secondary)
            if modManager.hasUnsavedProfileChanges {
                Button(nativeLocalized("Save Profile Changes")) { modManager.savePendingProfiles() }
            }
        }
    }

    private var languageSection: some View {
        Section(header: Text(nativeLocalized("Language")).font(.headline).foregroundColor(.starfruitBorder)) {
            Picker(nativeLocalized("Language"), selection: $nativeLanguage) {
                ForEach(NativeLocalization.shared.availableLanguages, id: \.id) { language in
                    Text(language.name).tag(language.id)
                }
            }
            Text(nativeLocalized("Translations are discovered from bundled language files. Untranslated text uses English."))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var launchModeSection: some View {
        Section(header: Text(nativeLocalized("Launch Mode")).font(.headline).foregroundColor(.starfruitBorder)) {
            Picker(nativeLocalized("Run Game Via"), selection: $useWine) {
                Text(nativeLocalized("Native macOS")).tag(false)
                Text(nativeLocalized("Wine / Crossover")).tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    private var nativeSettingsSection: some View {
        Section(header: Text(nativeLocalized("Native macOS Settings")).font(.headline).foregroundColor(.starfruitBorder)) {
            VStack(alignment: .leading) {
                Text(nativeLocalized("Native Game Directory")).font(.caption)
                TextField("/Applications/Stardew Valley.app/Contents/MacOS", text: $nativeSmapiDir)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading) {
                Text(nativeLocalized("Native Mods Directory (Optional)")).font(.caption)
                TextField("Default is Mods subfolder", text: $nativeModsDir)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var wineSettingsSection: some View {
        Section(header: Text(nativeLocalized("Wine Settings")).font(.headline).foregroundColor(.starfruitBorder)) {
            VStack(alignment: .leading) {
                Text(nativeLocalized("Wine Game Directory")).font(.caption)
                TextField("Path to Stardew Valley (Windows)", text: $wineSmapiDir)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading) {
                Text(nativeLocalized("Wine Mods Directory (Optional)")).font(.caption)
                TextField("Default is Mods subfolder", text: $wineModsDir)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading) {
                Text(nativeLocalized("Wine Prefix")).font(.caption)
                TextField("~/.wine", text: $winePrefix)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading) {
                Text(nativeLocalized("Wine Binary")).font(.caption)
                TextField("/opt/homebrew/bin/wine", text: $wineBinaryPath)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var appearanceSection: some View {
        Section(header: Text(nativeLocalized("Appearance")).font(.headline).foregroundColor(.starfruitBorder)) {
            HStack(spacing: 8) {
                ForEach([("system", "circle.lefthalf.filled", "System"),
                         ("light",  "sun.max.fill",          "Light"),
                         ("dark",   "moon.fill",             "Dark")], id: \.0) { tag, icon, label in
                    let isSelected = appearance == tag
                    Button(action: { appearance = tag }) {
                        HStack(spacing: 6) {
                            Image(systemName: icon)
                            Text(label)
                        }
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(isSelected
                            ? Color.starfruitAccent.opacity(0.2)
                            : Color.starfruitSecondary.opacity(0.08))
                        .foregroundColor(isSelected ? .starfruitAccent : .secondary)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color.starfruitAccent.opacity(0.6) : Color.starfruitBorder.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var animationCancelSection: some View {
        Section(header: Text(nativeLocalized("Animation Canceling")).font(.headline).foregroundColor(.starfruitBorder)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(nativeLocalized("Enable Animation Canceling"), isOn: $animationCancelManager.isEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(nativeLocalized("Delay"))
                        Spacer()
                        Text("\(Int(animationCancelManager.delayMs)) ms")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $animationCancelManager.delayMs, in: 1...500, step: 1)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nativeLocalized("Trigger"))
                        Text(animationCancelManager.triggerDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(animationCancelManager.isAwaitingTrigger ? "Listening..." : "Change Trigger...") {
                        animationCancelManager.beginAwaitingTrigger()
                    }
                    .buttonStyle(StarfruitButtonStyle())
                    .disabled(animationCancelManager.isAwaitingTrigger)
                }

                if animationCancelManager.isAwaitingTrigger {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(nativeLocalized("Press a key or mouse button. Press Escape to cancel."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(nativeLocalized("Cancel")) {
                            animationCancelManager.cancelAwaitingTrigger()
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
                }

                HStack {
                    Circle()
                        .fill(animationCancelManager.hasAccessibility ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(animationCancelManager.hasAccessibility ? "Accessibility permission granted" : "Accessibility permission required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !animationCancelManager.hasAccessibility {
                        Button(nativeLocalized("Open System Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                }

                Text(nativeLocalized("Animation cancel engine adapted from StardewAC by Matt Kingston / LittleBigDigital."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var autoclickerSection: some View {
        Section(header: Text(nativeLocalized("Autoclicker")).font(.headline).foregroundColor(.starfruitBorder)) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(nativeLocalized("Enable Autoclicker Hotkey"), isOn: $autoclickerManager.isEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(nativeLocalized("Click Delay"))
                        Spacer()
                        Text("\(Int(autoclickerManager.intervalMs)) ms")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $autoclickerManager.intervalMs, in: 10...1000, step: 10)
                }

                Picker(nativeLocalized("Click Button"), selection: $autoclickerManager.button) {
                    ForEach(AutoclickerManager.ClickButton.allCases) { button in
                        Text(button.label).tag(button)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(nativeLocalized("Toggle Key"))
                        Text(autoclickerManager.toggleKeyDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(autoclickerManager.isAwaitingToggleKey ? "Listening..." : "Change Key...") {
                        autoclickerManager.beginAwaitingToggleKey()
                    }
                    .buttonStyle(StarfruitButtonStyle())
                    .disabled(autoclickerManager.isAwaitingToggleKey)
                }

                if autoclickerManager.isAwaitingToggleKey {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(nativeLocalized("Press a key. Press Escape to cancel."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(nativeLocalized("Cancel")) {
                            autoclickerManager.cancelAwaitingToggleKey()
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
                }

                HStack {
                    Circle()
                        .fill(autoclickerManager.hasAccessibility ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(autoclickerManager.hasAccessibility ? "Accessibility permission granted" : "Accessibility permission required")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !autoclickerManager.hasAccessibility {
                        Button(nativeLocalized("Open System Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(StarfruitButtonStyle())
                    }
                }

                Text(nativeLocalized("Press the toggle key while Stardew Valley, SMAPI, CrossOver, or Wine Stardew is frontmost. Clicking stops immediately when focus leaves Stardew."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var nexusModsSection: some View {
        Section(header: Text(nativeLocalized("Nexus Mods")).font(.headline).foregroundColor(.starfruitBorder)) {
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
                    Button(nativeLocalized("Logout")) {
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
                        Text(nativeLocalized("Connect to Nexus Mods"))
                    }
                }
                .buttonStyle(StarfruitButtonStyle())
                .disabled(tempAPIKey.isEmpty || isValidating)
            }
        }
    }

    private var dataMigrationSection: some View {
        Section(header: Text(nativeLocalized("Data Migration")).font(.headline).foregroundColor(.starfruitBorder)) {
            Text(nativeLocalized("Older Starfruit data is imported automatically on first launch. Existing settings take priority, and original files are retained."))
                .font(.caption).foregroundColor(.secondary)
            if let report = modManager.legacyMigrationReport {
                Text("Imported \(report.importedProfiles) profiles and \(report.importedPresets) presets; preserved \(report.retainedProfiles ?? 0) existing profiles.")
                    .font(.caption)
                ForEach(report.issues, id: \.self) { Text($0).font(.caption).foregroundColor(.orange) }
            }
            if modManager.legacyCollectionImportCount > 0 {
                Text("Recognized \(modManager.legacyCollectionImportCount) installed collections without redownloading their mods.")
                    .font(.caption)
            }
            Button(action: {
                modManager.importOriginalProfiles()
            }) {
                Label(nativeLocalized("Retry Older Starfruit Import"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(StarfruitButtonStyle())
            .help(nativeLocalized("Retries incomplete imports without duplicating profiles or replacing newer settings."))
        }
    }

    private var deepLinkDebuggerSection: some View {
        Section(header: Text(nativeLocalized("Deep Link Debugger")).font(.headline).foregroundColor(.starfruitBorder)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(nativeLocalized("Manually test an NXM link or view received links."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("Paste nxm:// link here...", text: $testURLText)
                        .textFieldStyle(.roundedBorder)

                    Button(nativeLocalized("Test Link")) {
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
                    Text(nativeLocalized("Received Link Logs")).font(.subheadline).bold()
                    Spacer()
                    Button(nativeLocalized("Clear Logs")) {
                        modManager.clearDeepLinkLogs()
                    }
                    .buttonStyle(StarfruitButtonStyle())
                    .disabled(modManager.deepLinkLogs.isEmpty)
                }

                if modManager.deepLinkLogs.isEmpty {
                    Text(nativeLocalized("No deep links captured yet."))
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
}
