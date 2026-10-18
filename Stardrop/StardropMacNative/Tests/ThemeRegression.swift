import Foundation

@main
struct ThemeRegression {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StarfruitThemeTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = directory.appendingPathComponent("active.json")
        let imported = directory.appendingPathComponent("imported.json")
        let manager = NativeThemeManager(themeFileURL: active, watchChanges: false)
        precondition(manager.document == nil)

        try Data(##"{"name":"Test","colors":{"accent":{"dark":"#123456"}}}"##.utf8).write(to: imported)
        try manager.importTheme(from: imported)
        precondition(manager.document?.name == "Test")
        precondition(manager.document?.colors["accent"]?.dark == "#123456")
        precondition(manager.document?.colors["border"] == nil, "Unspecified colors must inherit defaults")

        try Data(##"{"name":"Edited","colors":{"accent":{"light":"#ABCDEF80"}}}"##.utf8).write(to: active)
        manager.reload()
        precondition(manager.document?.name == "Edited", "Active file edits must reload")

        try Data(#"{"name":"Invalid","colors":{"accent":{"dark":"garbage"}}}"#.utf8).write(to: imported)
        do {
            try manager.importTheme(from: imported)
            preconditionFailure("Invalid colors must be rejected before replacing the active theme")
        } catch {}
        precondition(manager.document?.name == "Edited")
        try Data("incomplete JSON".utf8).write(to: active)
        manager.reload()
        precondition(manager.document?.name == "Edited", "Incomplete editor saves must preserve the previous palette")
        precondition(manager.status != nil)

        let exported = directory.appendingPathComponent("exported.json")
        try manager.exportTheme(to: exported)
        let document = try JSONDecoder().decode(NativeThemeDocument.self, from: Data(contentsOf: exported))
        precondition(document.name == "Edited")
        try manager.reset()
        precondition(manager.document == nil && !FileManager.default.fileExists(atPath: active.path))
        print("PASS: theme import, inheritance, live reload, invalid-save recovery, export, reset")
    }
}
