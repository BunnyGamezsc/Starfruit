import SwiftUI
import Sparkle

@main
struct StarfruitMacApp: App {
    private let updaterController: SPUStandardUpdaterController

    @StateObject private var nexusClient: NexusClient
    @StateObject private var downloadManager: DownloadManager
    @StateObject private var modManager: ModManager
    @StateObject private var animationCancelManager: AnimationCancelManager
    @StateObject private var autoclickerManager: AutoclickerManager
    @AppStorage("appearance") private var appearance = "dark"
    @ObservedObject private var localization = NativeLocalization.shared

    init() {
        // Run migration from old bundle id -> new app layout/keychain/UserDefaults
        Migration.migrateIfNeeded()
        _nexusClient = StateObject(wrappedValue: NexusClient())
        _downloadManager = StateObject(wrappedValue: DownloadManager())
        _modManager = StateObject(wrappedValue: ModManager())
        _animationCancelManager = StateObject(wrappedValue: AnimationCancelManager())
        _autoclickerManager = StateObject(wrappedValue: AutoclickerManager())

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(nexusClient)
                .environmentObject(downloadManager)
                .environmentObject(modManager)
                .environmentObject(animationCancelManager)
                .environmentObject(autoclickerManager)
                .environment(\.locale, Locale(identifier: localization.language))
                .preferredColorScheme(preferredColorScheme)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    modManager.captureLaunchedProfileConfigs()
                }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowToolbarStyle(UnifiedWindowToolbarStyle())
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}
