import Foundation
import Combine
import AppKit

// MARK: - C Function Bindings (via @_silgen_name — no bridging header needed)
@_silgen_name("prepareApp") private func _prepareApp() -> Void
@_silgen_name("runApp")    private func _runApp() -> Void
@_silgen_name("stopApp")   private func _stopApp() -> Void
@_silgen_name("isAccessibilityEnabled") private func _isAccessibilityEnabled() -> Bool
@_silgen_name("setRepeatIntervalMilliseconds") private func _setRepeatInterval(_ ms: Int32) -> Void
@_silgen_name("setMouseTrigger") private func _setMouseTrigger(_ button: Int32, _ mods: UInt64) -> Void
@_silgen_name("setKeyTrigger")   private func _setKeyTrigger(_ keyCode: UInt16, _ mods: UInt64) -> Void

// MARK: - AnimationCancelManager

@MainActor
final class AnimationCancelManager: ObservableObject {

    // MARK: Persisted Settings
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "ac.enabled")
            if isEnabled {
                applySettings()
                startIfStardewFocused()
            } else {
                stopEngine()
            }
        }
    }

    @Published var delayMs: Double {
        didSet {
            let safeDelay = delayMs.isFinite ? min(max(delayMs, 1), 500) : 200
            if safeDelay != delayMs { delayMs = safeDelay }
            UserDefaults.standard.set(safeDelay, forKey: "ac.delayMs")
            _setRepeatInterval(Int32(safeDelay))
        }
    }

    /// "mouse" or "key"
    @Published var triggerType: String {
        didSet {
            UserDefaults.standard.set(triggerType, forKey: "ac.triggerType")
            applySettings()
        }
    }

    @Published var triggerKeyCode: Int {
        didSet {
            UserDefaults.standard.set(triggerKeyCode, forKey: "ac.triggerKeyCode")
            applySettings()
        }
    }

    @Published var triggerButtonNumber: Int {
        didSet {
            UserDefaults.standard.set(triggerButtonNumber, forKey: "ac.triggerButtonNumber")
            applySettings()
        }
    }

    @Published var triggerModifiers: String {
        didSet {
            UserDefaults.standard.set(triggerModifiers, forKey: "ac.triggerModifiers")
            applySettings()
        }
    }

    @Published var triggerDescription: String {
        didSet { UserDefaults.standard.set(triggerDescription, forKey: "ac.triggerDescription") }
    }

    // MARK: Runtime State
    @Published var isEngineRunning: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published var isAwaitingTrigger: Bool = false

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var focusObserver: NSObjectProtocol?
    private var engineRequested = false

    // MARK: Init
    init() {
        isEnabled           = UserDefaults.standard.bool(forKey: "ac.enabled")
        let savedDelay = UserDefaults.standard.object(forKey: "ac.delayMs") as? Double ?? 200
        delayMs = savedDelay.isFinite ? min(max(savedDelay, 1), 500) : 200
        triggerType         = UserDefaults.standard.string(forKey: "ac.triggerType") ?? "mouse"
        triggerKeyCode      = UserDefaults.standard.integer(forKey: "ac.triggerKeyCode")
        triggerButtonNumber = UserDefaults.standard.object(forKey: "ac.triggerButtonNumber") as? Int ?? 2
        triggerModifiers    = UserDefaults.standard.string(forKey: "ac.triggerModifiers") ?? ""
        triggerDescription  = UserDefaults.standard.string(forKey: "ac.triggerDescription") ?? "Middle Click"

        Task { @MainActor [weak self] in
            self?.onAppear()
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        hasAccessibility = _isAccessibilityEnabled()
        applySettings()
        observeFocusChanges()
        if isEnabled { startIfStardewFocused() }
    }

    func onDisappear() {
        stopEngine()
        removeMonitors()
        isAwaitingTrigger = false
        if let obs = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            focusObserver = nil
        }
    }

    // MARK: - Focus Observation

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
        hasAccessibility = _isAccessibilityEnabled()
        guard isEnabled, hasAccessibility, !isAwaitingTrigger else {
            stopEngine()
            return
        }
        if StardewAppDetector.isStardewApp(app) {
            startEngine()
        } else {
            stopEngine()
        }
    }

    private func startIfStardewFocused() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if StardewAppDetector.isStardewApp(frontmost) { startEngine() }
    }

    // MARK: - Engine Control

    func startEngine() {
        hasAccessibility = _isAccessibilityEnabled()
        guard isEnabled, hasAccessibility, !isAwaitingTrigger else { return }
        engineRequested = true
        guard !isEngineRunning else { return }
        isEngineRunning = true
        _prepareApp()
        engineRequested = false
        DispatchQueue.global(qos: .userInitiated).async {
            _runApp()
            Task { @MainActor in
                self.isEngineRunning = false
                self.hasAccessibility = _isAccessibilityEnabled()
                // Focus may have returned while the previous run was stopping.
                if self.engineRequested, self.isEnabled, self.hasAccessibility,
                   !self.isAwaitingTrigger, StardewAppDetector.isStardewFrontmost {
                    self.startEngine()
                }
            }
        }
    }

    func stopEngine() {
        engineRequested = false
        _stopApp()
    }

    // MARK: - Settings Application

    func applySettings() {
        let delay = delayMs.isFinite ? min(max(delayMs, 1), 500) : 200
        _setRepeatInterval(Int32(delay))
        let mask = modifierMask(from: triggerModifiers)
        if triggerType == "mouse" {
            guard (1...31).contains(triggerButtonNumber) else { return }
            _setMouseTrigger(Int32(triggerButtonNumber), mask)
        } else if triggerType == "key" {
            guard (0...127).contains(triggerKeyCode) else { return }
            _setKeyTrigger(UInt16(triggerKeyCode), mask)
        }
    }

    // MARK: - Trigger Assignment UI

    func beginAwaitingTrigger() {
        removeMonitors()
        stopEngine()
        isAwaitingTrigger = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            Task { @MainActor in self?.handleKeyEvent(event) }
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleMouseEvent(event) }
            return nil
        }
    }

    func cancelAwaitingTrigger() {
        removeMonitors()
        isAwaitingTrigger = false
        if isEnabled { startIfStardewFocused() }
    }

    private func removeMonitors() {
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor   = nil }
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        if event.keyCode == 53 { cancelAwaitingTrigger(); return } // Escape
        let mods = describeModifiers(event.modifierFlags)
        let key  = event.charactersIgnoringModifiers ?? "Key"
        triggerDescription  = mods.isEmpty ? key : "\(mods)+\(key)"
        triggerType         = "key"
        triggerKeyCode      = Int(event.keyCode)
        triggerButtonNumber = -1
        triggerModifiers    = mods
        removeMonitors()
        isAwaitingTrigger = false
        applySettings()
        if isEnabled { startIfStardewFocused() }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        let mods = describeModifiers(event.modifierFlags)
        var buttonNumber = Int(event.buttonNumber)
        let buttonName: String
        switch event.type {
        case .rightMouseDown:
            buttonName = "Right Click"
            if buttonNumber == 0 { buttonNumber = 1 }
        case .otherMouseDown:
            buttonName = event.buttonNumber == 2 ? "Middle Click" : "Mouse Button \(event.buttonNumber)"
        default:
            buttonName = "Mouse"
        }
        triggerDescription  = mods.isEmpty ? buttonName : "\(mods)+\(buttonName)"
        triggerType         = "mouse"
        triggerKeyCode      = -1
        triggerButtonNumber = buttonNumber
        triggerModifiers    = mods
        removeMonitors()
        isAwaitingTrigger = false
        applySettings()
        if isEnabled { startIfStardewFocused() }
    }

    // MARK: - Helpers

    private func describeModifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("fn") }
        if flags.contains(.control)  { parts.append("ctrl") }
        if flags.contains(.command)  { parts.append("cmd") }
        if flags.contains(.option)   { parts.append("opt") }
        if flags.contains(.shift)    { parts.append("shift") }
        return parts.joined(separator: "+")
    }

    func modifierMask(from mods: String) -> UInt64 {
        var mask: UInt64 = 0
        for p in mods.split(separator: "+").map(String.init) {
            switch p {
            case "ctrl":  mask |= (1 << 0)
            case "cmd":   mask |= (1 << 1)
            case "opt":   mask |= (1 << 2)
            case "shift": mask |= (1 << 3)
            case "fn":    mask |= (1 << 4)
            default: break
            }
        }
        return mask
    }
}
