import SwiftUI

enum NativeModColumn: String, CaseIterable, Identifiable, Codable {
    case name, version, status, notes, changelog
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Mod Name"
        case .version: return "Version"
        case .status: return "Status"
        case .notes: return "Notes"
        case .changelog: return "Changelog"
        }
    }
    var width: CGFloat? {
        switch self {
        case .name: return nil
        case .version: return 80
        case .status: return 105
        case .notes: return 120
        case .changelog: return 80
        }
    }
}

struct NativeModListPreferences: Codable {
    var order: [NativeModColumn] = NativeModColumn.allCases
    var hidden: Set<NativeModColumn> = [.notes, .changelog]
    var visibleColumns: [NativeModColumn] { order.filter { !hidden.contains($0) } }

    static func decode(_ value: String) -> Self {
        guard let data = value.data(using: .utf8),
              var preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        // Keep future columns available and discard duplicated persisted entries.
        var seen = Set<NativeModColumn>()
        preferences.order = preferences.order.filter { seen.insert($0).inserted }
        preferences.order += NativeModColumn.allCases.filter { !seen.contains($0) }
        preferences.hidden.remove(.name)
        return preferences
    }
    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct NativeModColumnsEditor: View {
    @ObservedObject private var localization = NativeLocalization.shared
    @ObservedObject private var themeManager = NativeThemeManager.shared
    @Binding var storedPreferences: String
    @Environment(\.dismiss) private var dismiss
    private var preferences: NativeModListPreferences { .decode(storedPreferences) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(nativeLocalized("Mod List Columns")).font(.title2.bold())
            Text(nativeLocalized("Choose visible columns and move them into the order you prefer."))
                .foregroundColor(.secondary)
            ForEach(preferences.order) { column in
                HStack {
                    Toggle(nativeLocalized(column.title), isOn: Binding(get: {
                        !preferences.hidden.contains(column)
                    }, set: { visible in
                        var value = preferences
                        if visible { value.hidden.remove(column) } else { value.hidden.insert(column) }
                        storedPreferences = value.encoded
                    }))
                    .disabled(column == .name)
                    Spacer()
                    Button { move(column, by: -1) } label: { Image(systemName: "arrow.up") }
                        .disabled(preferences.order.first == column)
                        .help(nativeLocalized("Move column left"))
                    Button { move(column, by: 1) } label: { Image(systemName: "arrow.down") }
                        .disabled(preferences.order.last == column)
                        .help(nativeLocalized("Move column right"))
                }
            }
            HStack {
                Button(nativeLocalized("Reset Columns")) { storedPreferences = NativeModListPreferences().encoded }
                Spacer()
                Button(nativeLocalized("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func move(_ column: NativeModColumn, by delta: Int) {
        var value = preferences
        guard let index = value.order.firstIndex(of: column), value.order.indices.contains(index + delta) else { return }
        value.order.swapAt(index, index + delta)
        storedPreferences = value.encoded
    }
}
