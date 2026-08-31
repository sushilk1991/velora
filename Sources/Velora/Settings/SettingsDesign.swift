import AppKit
import SwiftUI

// Shared visual language for the card-based settings panes (Stats, Shortcuts).
// Everything renders with solid system colors — the offscreen snapshot
// renderer composites materials as blank surfaces, so cards use
// `textBackgroundColor` on the window background plus a hairline, the same
// recipe the grouped Form boxes resolve to.

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
                .fill(Color(nsColor: .textBackgroundColor)))
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
                .fill(Color(nsColor: .textBackgroundColor)))
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
