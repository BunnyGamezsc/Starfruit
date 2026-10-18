import AppKit
import CoreGraphics
import Foundation
import ApplicationServices

// tiny HUD notifier
struct Notifier {
    static func show(_ text: String) {
        DispatchQueue.main.async {
            let width: CGFloat = 300
            let height: CGFloat = 48
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .statusBar
            window.hasShadow = true
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            container.wantsLayer = true
            container.layer?.cornerRadius = 10
            container.layer?.masksToBounds = true
            container.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.88).cgColor

            // Accent bar on left
            let accent = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: height))
            accent.wantsLayer = true
            accent.layer?.backgroundColor = NSColor.systemOrange.cgColor
            container.addSubview(accent)

            let label = NSTextField(labelWithString: text)
            label.textColor = NSColor.white
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.alignment = .center
            label.backgroundColor = .clear
            label.frame = NSRect(x: 16, y: 12, width: width - 32, height: 24)
            container.addSubview(label)

            window.contentView = container

            if let screen = NSScreen.main {
                let x = (screen.frame.width - window.frame.width) / 2
                let y = screen.frame.height * 0.82
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }

            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                window.animator().alphaValue = 1.0
            }, completionHandler: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.28
                        window.animator().alphaValue = 0
                    }, completionHandler: {
                        window.orderOut(nil)
                    })
                }
            })
        }
    }
}

@MainActor
final class AutoclickerManager: ObservableObject {
    enum ClickButton: String, CaseIterable, Identifiable {
        case left
        case right

        var id: String { rawValue }

        var label: String {
            switch self {
            case .left: return "Left"
            case .right: return "Right"
            }
        }

        var cgButton: CGMouseButton {
            switch self {
            case .left: return .left
            case .right: return .right
            }
        }

        var downEventType: CGEventType {
            switch self {
            case .left: return .leftMouseDown
            case .right: return .rightMouseDown
            }
        }

        var upEventType: CGEventType {
            switch self {
            case .left: return .leftMouseUp
            case .right: return .rightMouseUp
            }
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            let changed = oldValue != isEnabled
            UserDefaults.standard.set(isEnabled, forKey: "autoclicker.enabled")
            if !isEnabled { stopClicking(showHUD: false) }
            if changed {
                Notifier.show(isEnabled ? "Autoclicker Enabled" : "Autoclicker Disabled")
            }
        }
    }

    @Published var intervalMs: Double {
        didSet {
            let clamped = min(max(intervalMs, 10), 5000)
            if clamped != intervalMs {
                intervalMs = clamped
                return
            }
            UserDefaults.standard.set(intervalMs, forKey: "autoclicker.intervalMs")
            if isClicking { restartTimer() }
        }
    }

    @Published var button: ClickButton {
        didSet {
            UserDefaults.standard.set(button.rawValue, forKey: "autoclicker.button")
        }
    }

    @Published var toggleKeyCode: Int {
        didSet {
            UserDefaults.standard.set(toggleKeyCode, forKey: "autoclicker.toggleKeyCode")
            toggleKeyDescription = Self.describeKeyCode(toggleKeyCode)
        }
    }

    @Published var toggleKeyDescription: String {
        didSet {
            UserDefaults.standard.set(toggleKeyDescription, forKey: "autoclicker.toggleKeyDescription")
        }
    }

    @Published private(set) var isClicking = false
    @Published private(set) var hasAccessibility = false
    @Published private(set) var isAwaitingToggleKey = false

    private var focusObserver: NSObjectProtocol?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var captureKeyMonitor: Any?
    private var timer: Timer?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "autoclicker.enabled")
        intervalMs = UserDefaults.standard.object(forKey: "autoclicker.intervalMs") as? Double ?? 100
        let savedButton = UserDefaults.standard.string(forKey: "autoclicker.button") ?? ClickButton.left.rawValue
        button = ClickButton(rawValue: savedButton) ?? .left
        toggleKeyCode = UserDefaults.standard.object(forKey: "autoclicker.toggleKeyCode") as? Int ?? 100
        toggleKeyDescription = UserDefaults.standard.string(forKey: "autoclicker.toggleKeyDescription") ?? Self.describeKeyCode(100)

        Task { @MainActor [weak self] in
            self?.onAppear()
        }
    }

    func onAppear() {
        hasAccessibility = AXIsProcessTrusted()
        observeFocusChanges()
        observeToggleKey()
    }

    func onDisappear() {
        stopClicking(showHUD: false)
        removeKeyMonitors()
        if let focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(focusObserver)
            self.focusObserver = nil
        }
    }

    private func observeFocusChanges() {
        guard focusObserver == nil else { return }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self.handleFocusChange(to: app)
            }
        }
    }

    private func handleFocusChange(to app: NSRunningApplication?) {
        hasAccessibility = AXIsProcessTrusted()
        if !StardewAppDetector.isStardewApp(app) {
            stopClicking(showHUD: false)
        }
    }

    private func toggleClickingFromHotkey() {
        // Hotkey should always show user-visible feedback for toggle attempts
        if !isEnabled {
            Notifier.show("Autoclicker Disabled")
            return
        }

        // If currently clicking -> stop immediately (no frontmost requirement)
        if isClicking {
            stopClicking(showHUD: true)
            return
        }

        // Try to start
        hasAccessibility = AXIsProcessTrusted()
        if !hasAccessibility {
            // prompt user to enable Accessibility
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            hasAccessibility = AXIsProcessTrusted()
            if !hasAccessibility {
                Notifier.show("Enable Accessibility to use autoclicker")
                return
            }
        }

        guard StardewAppDetector.isStardewFrontmost else {
            Notifier.show("Focus Stardew to start autoclicker")
            return
        }

        startClicking(showHUD: true)
    }

    private func observeToggleKey() {
        guard globalKeyMonitor == nil, localKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleToggleKeyEvent(event) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleToggleKeyEvent(event) }
            return event
        }
    }

    private func removeKeyMonitors() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let captureKeyMonitor {
            NSEvent.removeMonitor(captureKeyMonitor)
            self.captureKeyMonitor = nil
        }
    }

    private func handleToggleKeyEvent(_ event: NSEvent) {
        guard !isAwaitingToggleKey, Int(event.keyCode) == toggleKeyCode else { return }
        toggleClickingFromHotkey()
    }

    private func startClicking(showHUD: Bool = true) {
        guard !isClicking else { return }
        isClicking = true
        restartTimer()
        if showHUD { Notifier.show("Autoclicker ON") }
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = max(intervalMs, 10) / 1000
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.clickIfAllowed()
            }
        }
    }

    private func stopClicking(showHUD: Bool = true) {
        timer?.invalidate()
        timer = nil
        isClicking = false
        if showHUD { Notifier.show("Autoclicker OFF") }
    }

    private func clickIfAllowed() {
        hasAccessibility = AXIsProcessTrusted()
        guard isEnabled, hasAccessibility, StardewAppDetector.isStardewFrontmost else {
            stopClicking(showHUD: false)
            return
        }

        let location = CGEvent(source: nil)?.location ?? NSEvent.mouseLocation
        guard let down = CGEvent(mouseEventSource: nil, mouseType: button.downEventType, mouseCursorPosition: location, mouseButton: button.cgButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: button.upEventType, mouseCursorPosition: location, mouseButton: button.cgButton) else {
            return
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func beginAwaitingToggleKey() {
        isAwaitingToggleKey = true
        stopClicking(showHUD: false)
        if let captureKeyMonitor {
            NSEvent.removeMonitor(captureKeyMonitor)
        }
        captureKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.captureToggleKey(event) }
            return nil
        }
    }

    func cancelAwaitingToggleKey() {
        if let captureKeyMonitor {
            NSEvent.removeMonitor(captureKeyMonitor)
            self.captureKeyMonitor = nil
        }
        isAwaitingToggleKey = false
    }

    private func captureToggleKey(_ event: NSEvent) {
        if event.keyCode == 53 {
            cancelAwaitingToggleKey()
            return
        }

        toggleKeyCode = Int(event.keyCode)
        toggleKeyDescription = Self.describeKeyEvent(event)
        cancelAwaitingToggleKey()
    }

    private static func describeKeyEvent(_ event: NSEvent) -> String {
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return describeKeyCode(Int(event.keyCode))
    }

    private static func describeKeyCode(_ keyCode: Int) -> String {
        switch keyCode {
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 49: return "Space"
        case 53: return "Escape"
        default: return "Key \(keyCode)"
        }
    }
}
