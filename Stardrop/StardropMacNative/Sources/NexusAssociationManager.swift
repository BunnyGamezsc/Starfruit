import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers

@MainActor
final class NexusAssociationManager: ObservableObject {
    @Published private(set) var isDefaultHandler = false
    @Published private(set) var handlerName = "None"
    @Published private(set) var message: String?
    private let previousHandlerKey = "native.previousNXMHandler"

    init() { refresh() }

    func refresh() {
        let handler = currentHandlerID()
        isDefaultHandler = Bundle.main.bundleIdentifier != nil && handler == Bundle.main.bundleIdentifier
        if let handler, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: handler) {
            handlerName = FileManager.default.displayName(atPath: url.path)
        } else {
            handlerName = handler ?? "None"
        }
    }

    func register() {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            message = "Open the packaged Starfruit app to register Nexus links."
            return
        }
        if let previous = currentHandlerID(), previous != bundleID {
            UserDefaults.standard.set(previous, forKey: previousHandlerKey)
        }
        let registration = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        guard registration == noErr else { report(registration); return }
        setHandler(bundleID)
    }

    func remove() {
        refresh()
        guard isDefaultHandler else {
            message = "Starfruit is not the current Nexus link handler."
            return
        }
        if let previous = UserDefaults.standard.string(forKey: previousHandlerKey),
           previous != Bundle.main.bundleIdentifier,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: previous) != nil {
            setHandler(previous)
            return
        }
        // LaunchServices has no public API to clear a URL scheme handler. Let
        // the user select its replacement rather than assign an invalid ID.
        let panel = NSOpenPanel()
        panel.title = "Choose another app for Nexus links"
        panel.prompt = "Use This App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        guard bundleID != Bundle.main.bundleIdentifier else {
            message = "Choose a different application to remove Starfruit as the default."
            return
        }
        let registration = LSRegisterURL(url as CFURL, true)
        guard registration == noErr else { report(registration); return }
        setHandler(bundleID)
    }

    private func currentHandlerID() -> String? {
        guard let sample = URL(string: "nxm://stardewvalley"),
              let application = NSWorkspace.shared.urlForApplication(toOpen: sample) else { return nil }
        return Bundle(url: application)?.bundleIdentifier
    }

    private func setHandler(_ bundleID: String) {
        let result = LSSetDefaultHandlerForURLScheme("nxm" as CFString, bundleID as CFString)
        guard result == noErr else { report(result); return }
        refresh()
        message = isDefaultHandler ? "Nexus links now open in Starfruit." : "Nexus links now open in \(handlerName)."
    }

    private func report(_ status: OSStatus) {
        message = "Could not change the Nexus link association: \(NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription)"
        refresh()
    }
}

struct NexusAssociationSettingsView: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @StateObject private var association = NexusAssociationManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(nativeLocalized("Nexus Link Association")).font(.headline)
            Text("Current handler: \(association.handlerName)").foregroundColor(.secondary)
            HStack {
                Button(nativeLocalized("Register NXM Links")) { association.register() }
                    .disabled(association.isDefaultHandler)
                Button(nativeLocalized("Remove Starfruit Association")) { association.remove() }
                    .disabled(!association.isDefaultHandler)
                Button { association.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help(nativeLocalized("Refresh link association status"))
            }
            Text(nativeLocalized("Removing restores the previous app, or lets you choose another app for Nexus links."))
                .font(.caption).foregroundColor(.secondary)
            if let message = association.message {
                Text(message).font(.caption).textSelection(.enabled)
            }
        }
        .onAppear { association.refresh() }
    }
}
