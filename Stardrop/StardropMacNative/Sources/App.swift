import SwiftUI

@main
struct StarfruitMacApp: App {
    @StateObject private var nexusClient = NexusClient()
    @StateObject private var downloadManager = DownloadManager()
    @StateObject private var modManager = ModManager()
    @AppStorage("appearance") private var appearance = "system"
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(nexusClient)
                .environmentObject(downloadManager)
                .environmentObject(modManager)
                .preferredColorScheme(.dark)
        }
        .windowToolbarStyle(UnifiedWindowToolbarStyle())
    }
}
