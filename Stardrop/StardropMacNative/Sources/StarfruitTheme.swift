import SwiftUI

extension Color {
    static let starfruitBackground = Color(red: 0.0, green: 0.05, blue: 0.15)
    static let starfruitBorder = Color(red: 0.0, green: 0.8, blue: 0.8) // Cyan
    static let starfruitAccent = Color(red: 1.0, green: 0.5, blue: 0.0) // Orange
    static let starfruitSecondary = Color(red: 0.0, green: 0.4, blue: 0.6) // Blue
    static let starfruitText = Color.white
}

struct StarfruitPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(Color.starfruitBackground.opacity(0.9))
            .foregroundColor(.white)
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
