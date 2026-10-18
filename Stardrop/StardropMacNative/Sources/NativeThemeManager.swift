import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NativeThemeColors: Codable {
    var light: String?
    var dark: String?
}

struct NativeThemeDocument: Codable {
    var name: String
    var colors: [String: NativeThemeColors]

    static let example = NativeThemeDocument(name: "Starfruit", colors: [
        "background": .init(light: "#F2FAFA", dark: "#000D26"),
        "panel": .init(light: "#FFFCF5", dark: "#000D26"),
        "border": .init(light: "#007A8F", dark: "#00CCCC"),
        "accent": .init(light: "#DB5714", dark: "#FF8000"),
        "secondary": .init(light: "#00739E", dark: "#006699"),
        "text": .init(light: "#141F29", dark: "#FFFFFF")
    ])
}

@MainActor
final class NativeThemeManager: ObservableObject {
    static let shared = NativeThemeManager()
    @Published private(set) var document: NativeThemeDocument?
    @Published private(set) var status: String?
    private var lastData: Data?
    private var timer: Timer?
    private let fileURL: URL

    var themeFileURL: URL { fileURL }

    init(themeFileURL: URL? = nil, watchChanges: Bool = true) {
        fileURL = themeFileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Starfruit/Themes/Current.json")
        reload()
        if watchChanges {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reload() }
            }
        }
    }

    func importTheme(from url: URL) throws {
        let data = try Data(contentsOf: url)
        _ = try validatedDocument(data)
        try FileManager.default.createDirectory(at: themeFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: themeFileURL, options: .atomic)
        reload()
    }

    func exportTheme(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document ?? .example).write(to: url, options: .atomic)
    }

    func reset() throws {
        if FileManager.default.fileExists(atPath: themeFileURL.path) {
            try FileManager.default.removeItem(at: themeFileURL)
        }
        lastData = nil
        document = nil
        status = nil
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: themeFileURL.path) else {
            if document != nil { document = nil; lastData = nil }
            return
        }
        do {
            let data = try Data(contentsOf: themeFileURL)
            guard data != lastData else { return }
            let parsed = try validatedDocument(data)
            lastData = data
            document = parsed
            status = nil
        } catch {
            // Keep the last valid palette while an editor is saving a file.
            let message = error.localizedDescription
            if status != message { status = message }
        }
    }

    func color(_ key: String, light: NSColor, dark: NSColor) -> Color {
        let overrides = document?.colors[key]
        return Color(light: overrides?.light.flatMap(Self.parseColor) ?? light,
                     dark: overrides?.dark.flatMap(Self.parseColor) ?? dark)
    }

    private func validatedDocument(_ data: Data) throws -> NativeThemeDocument {
        guard data.count <= 262_144 else { throw ThemeError.invalid("Theme is larger than 256 KB.") }
        let parsed = try JSONDecoder().decode(NativeThemeDocument.self, from: data)
        let keys = Set(NativeThemeDocument.example.colors.keys)
        for (key, colors) in parsed.colors {
            guard keys.contains(key) else { throw ThemeError.invalid("Unknown theme color: \(key)") }
            for value in [colors.light, colors.dark].compactMap({ $0 }) {
                guard Self.parseColor(value) != nil else { throw ThemeError.invalid("Invalid color \(value); use #RRGGBB or #RRGGBBAA.") }
            }
        }
        return parsed
    }

    private static func parseColor(_ text: String) -> NSColor? {
        guard text.hasPrefix("#"), [7, 9].contains(text.count),
              let value = UInt64(text.dropFirst(), radix: 16) else { return nil }
        let hasAlpha = text.count == 9
        let rgb = hasAlpha ? value >> 8 : value
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                       green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255,
                       alpha: hasAlpha ? Double(value & 255) / 255 : 1)
    }

    private enum ThemeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}

struct NativeThemeSettingsView: View {
    @ObservedObject private var theme = NativeThemeManager.shared
    @ObservedObject private var localization = NativeLocalization.shared
    @NativeState private var errorMessage: String?

    var body: some View {
        Section(header: Text(nativeLocalized("Custom Theme")).font(.headline).foregroundColor(.starfruitBorder)) {
            Text(theme.document?.name ?? nativeLocalized("Starfruit Defaults"))
            HStack {
                Button(nativeLocalized("Import Theme…"), action: importTheme)
                Button(nativeLocalized("Export Theme…"), action: exportTheme)
                Button(nativeLocalized("Reset")) { perform { try theme.reset() } }
                    .disabled(theme.document == nil)
                Button(nativeLocalized("Show Theme File")) {
                    NSWorkspace.shared.activateFileViewerSelecting([theme.themeFileURL])
                }.disabled(theme.document == nil)
            }
            Text(nativeLocalized("JSON color overrides inherit Starfruit defaults. Edits to the active theme file reload automatically."))
                .font(.caption).foregroundColor(.secondary)
            if let message = errorMessage ?? theme.status { Text(message).font(.caption).foregroundColor(.red) }
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { perform { try theme.importTheme(from: url) } }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Starfruit-theme.json"
        if panel.runModal() == .OK, let url = panel.url { perform { try theme.exportTheme(to: url) } }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
