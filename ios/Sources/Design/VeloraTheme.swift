import SwiftUI

enum VeloraTheme {
    static let violet = Color(red: 0.39, green: 0.18, blue: 0.90)
    static let violetDark = Color(red: 0.20, green: 0.08, blue: 0.50)
    static let warmAccent = Color(red: 0.98, green: 0.55, blue: 0.27)

    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.055, green: 0.047, blue: 0.078)
            : Color(red: 0.975, green: 0.965, blue: 0.94)
    }

    static func raised(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.105, green: 0.09, blue: 0.14)
            : Color(red: 1.0, green: 0.995, blue: 0.98)
    }
}
