import Foundation

/// Display-only ordering. Download size never stands in for runtime RAM.
enum ModelChoiceOrder {
    static func downloadBytes(_ label: String) -> Double {
        let parts = label.uppercased().split(separator: " ")
        guard let first = parts.first, let value = Double(first), value.isFinite, value >= 0 else {
            return .infinity
        }
        let unit = parts.dropFirst().first.map(String.init) ?? "B"
        let factor: Double
        switch unit {
        case "GB", "GIB": factor = 1_000_000_000
        case "MB", "MIB": factor = 1_000_000
        case "KB", "KIB": factor = 1_000
        case "B": factor = 1
        default: return .infinity
        }
        return value * factor
    }
}
