import Foundation
import Combine

/// Uses Stardrop's translations without depending on the Avalonia application.
@MainActor
final class NativeLocalization: ObservableObject {
    static let shared = NativeLocalization()

    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "nativeLanguage") }
    }
    private let dictionaries: [String: [String: String]]
    private let keysByEnglishText: [String: String]

    var availableLanguages: [(id: String, name: String)] {
        dictionaries.keys.sorted().map { code in
            let locale = Locale(identifier: code)
            return (code, locale.localizedString(forLanguageCode: code)?.capitalized ?? code)
        }
    }

    private init() {
        language = UserDefaults.standard.string(forKey: "nativeLanguage") ?? "en"
        var loaded: [String: [String: String]] = [:]
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("i18n"),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let entries = try? JSONDecoder().decode([String: String].self, from: data) {
                    loaded[file.deletingPathExtension().lastPathComponent] = entries
                }
            }
        }
        if loaded["en"] == nil { loaded["en"] = [:] }
        dictionaries = loaded
        var reverse: [String: String] = [:]
        for (key, value) in (loaded["en"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            if reverse[value] == nil { reverse[value] = key }
        }
        keysByEnglishText = reverse
    }

    func text(_ english: String) -> String {
        guard language != "en", let key = keysByEnglishText[english],
              let translated = dictionaries[language]?[key], !translated.isEmpty else { return english }
        return translated
    }
}

@MainActor
func nativeLocalized(_ english: String) -> String {
    NativeLocalization.shared.text(english)
}
