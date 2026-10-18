import SwiftUI
import AppKit

extension Color {
    @MainActor static var starfruitBackground: Color { NativeThemeManager.shared.color("background",
        light: NSColor(red: 0.95, green: 0.98, blue: 0.98, alpha: 1.0),
        dark: NSColor(red: 0.0, green: 0.05, blue: 0.15, alpha: 1.0)
    ) }
    @MainActor static var starfruitPanelBackground: Color { NativeThemeManager.shared.color("panel",
        light: NSColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 1.0),
        dark: NSColor(red: 0.0, green: 0.05, blue: 0.15, alpha: 1.0)
    ) }
    @MainActor static var starfruitBorder: Color { NativeThemeManager.shared.color("border",
        light: NSColor(red: 0.0, green: 0.48, blue: 0.56, alpha: 1.0),
        dark: NSColor(red: 0.0, green: 0.8, blue: 0.8, alpha: 1.0)
    ) }
    @MainActor static var starfruitAccent: Color { NativeThemeManager.shared.color("accent",
        light: NSColor(red: 0.86, green: 0.34, blue: 0.08, alpha: 1.0),
        dark: NSColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0)
    ) }
    @MainActor static var starfruitSecondary: Color { NativeThemeManager.shared.color("secondary",
        light: NSColor(red: 0.0, green: 0.45, blue: 0.62, alpha: 1.0),
        dark: NSColor(red: 0.0, green: 0.4, blue: 0.6, alpha: 1.0)
    ) }
    @MainActor static var starfruitText: Color { NativeThemeManager.shared.color("text",
        light: NSColor(red: 0.08, green: 0.12, blue: 0.16, alpha: 1.0),
        dark: NSColor.white
    ) }

    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

struct StarfruitPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.starfruitPanelBackground.opacity(0.92))
            .foregroundColor(.primary)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.starfruitBorder, lineWidth: 2)
            )
            .shadow(color: Color.starfruitBorder.opacity(0.3), radius: 10)
    }
}

extension View {
    func starfruitPanel() -> some View {
        self.modifier(StarfruitPanelModifier())
    }
}

struct StarfruitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Color.starfruitAccent : Color.starfruitSecondary)
            .foregroundColor(.white)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.starfruitBorder, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}
