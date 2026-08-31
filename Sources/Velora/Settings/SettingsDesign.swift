import AppKit
import SwiftUI

// Shared visual language for the settings window. Everything renders with
// solid colors — the offscreen snapshot renderer composites materials as
// blank surfaces — and every pane sits on the one canvas/card pair below
// (grouped Forms hide their own scroll background to reveal it), so the
// whole window reads as a single surface in both themes.

/// The settings window's canonical background pair. Canvas is the window and
/// pane ground, card the elevated surface on top of it. Defined as explicit
/// sRGB values because no public semantic NSColor gives one consistent
/// answer across Forms, ScrollViews, and the titlebar.
enum VeloraPanel {
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 48 / 255, alpha: 1)
            : NSColor(srgbRed: 247 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
    }

    static let cardColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 41 / 255, green: 41 / 255, blue: 41 / 255, alpha: 1)
            : NSColor.white
    }

    static let canvas = Color(nsColor: canvasColor)
    static let card = Color(nsColor: cardColor)
}

/// One elevated card: rounded 12 pt surface, hairline border, whisper shadow.
struct SettingsCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            content
        }
        .padding(VeloraSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VeloraPanel.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
    }
}

/// Colored gradient icon tile — the sidebar's tile idiom, reusable at any size.
struct IconTile: View {
    let symbol: String
    let color: Color
    var side: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Card header: gradient icon tile + title (+ optional subtitle), with room
/// for a trailing control (usually the feature's master toggle).
struct CardHeader<Trailing: View>: View {
    let symbol: String
    let color: Color
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: VeloraSpacing.m) {
            IconTile(symbol: symbol, color: color, side: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(symbol: String, color: Color, title: String, subtitle: String? = nil) {
        self.init(
            symbol: symbol, color: color, title: title, subtitle: subtitle
        ) { EmptyView() }
    }
}

/// Hero metric tile: big rounded number over a caption, led by a tinted icon.
struct StatTile: View {
    let symbol: String
    let color: Color
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            IconTile(symbol: symbol, color: color, side: 26)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(VeloraSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(VeloraPanel.card))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }
}

/// A keyboard shortcut drawn as physical keycaps: one cap per modifier
/// symbol, one for the key ("⌃⇧A" → [⌃][⇧][A]). Bare-modifier shortcuts
/// ("⌥ right") render as a single wider cap.
struct KeycapsLabel: View {
    let hotkey: Hotkey

    private var caps: [String] {
        let label = hotkey.displayLabel
        if hotkey.isModifierOnly { return [label] }
        var symbols: [String] = []
        var rest = label[...]
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            symbols.append(String(first))
            rest = rest.dropFirst()
        }
        let key = String(rest)
        return key.isEmpty ? symbols : symbols + [key]
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .padding(.horizontal, cap.count > 1 ? 8 : 0)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hotkey.displayName)
    }
}

/// Label/value row inside a card — the card-world sibling of LabeledContent.
struct CardMetricRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: VeloraSpacing.m)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
        }
    }
}

/// Hairline divider tuned for card interiors.
struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.6))
            .frame(height: 1)
    }
}
