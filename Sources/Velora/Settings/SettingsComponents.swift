import SwiftUI

/// Full-width scrollable container for Settings tabs. The ScrollView spans the
/// entire detail column so the macOS scrollbar always hugs the window edge,
/// while inner grids adapt seamlessly between 1 column (≤ 760 pt) and 2 columns
/// (wide windows) with zero wasted right-hand void.
struct SettingsCanvas<Content: View>: View {
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (_ isWide: Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let isWide = proxy.size.width >= 760
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                    content(isWide)
                }
                .padding(.top, VeloraSpacing.xs)
                .padding(.bottom, VeloraSpacing.xl)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// Two balanced columns on wide windows, collapsing cleanly to one column at
/// narrow window widths (960 pt minimum or narrow standalone snapshots).
struct SettingsAdaptiveColumns<Left: View, Right: View>: View {
    let isWide: Bool
    var spacing: CGFloat = VeloraSpacing.l
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        if isWide {
            HStack(alignment: .top, spacing: spacing) {
                VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                    left()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                    right()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: VeloraSpacing.l) {
                left()
                right()
            }
        }
    }
}

/// Elevated Settings card built strictly from Velora's design tokens
/// (`VeloraPanel.card`, `VeloraPanel.hairline`, `VeloraRadius.card`), with an
/// optional icon-badged header, trailing pill/caption, hairline-separated rows,
/// and left-aligned footer.
struct SettingsCard<HeaderTrailing: View, Content: View>: View {
    private let title: String?
    private let symbol: String?
    private let tint: Color
    private let footer: String?
    private let headerTrailing: HeaderTrailing
    private let content: Content

    init(
        title: String? = nil,
        symbol: String? = nil,
        tint: Color = VeloraBrand.accent,
        footer: String? = nil,
        @ViewBuilder headerTrailing: () -> HeaderTrailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.footer = footer
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            if let title {
                HStack(alignment: .center, spacing: VeloraSpacing.s) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(tint.opacity(0.14)))
                            .accessibilityHidden(true)
                    }
                    Text(L10n.text(title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: VeloraSpacing.s)
                    headerTrailing
                }
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .fill(VeloraPanel.card))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                    .strokeBorder(VeloraPanel.hairline, lineWidth: 1))

            if let footer, !footer.isEmpty {
                SettingsFooter(footer)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension SettingsCard where HeaderTrailing == EmptyView {
    init(
        title: String? = nil,
        symbol: String? = nil,
        tint: Color = VeloraBrand.accent,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, symbol: symbol, tint: tint, footer: footer,
            headerTrailing: { EmptyView() }, content: content)
    }
}

/// Standard Settings row inside `SettingsCard`: crisp 13 pt label, optional
/// 11.5 pt secondary caption, and trailing control.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: VeloraSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(L10n.text(subtitle))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: VeloraSpacing.m)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
    }
}

/// Toggle row inside `SettingsCard` with switch style and optional subtitle.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(L10n.text(title))
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

/// Compact pill badge used in Settings headers and model/status rows.
struct SettingsStatusPill: View {
    let text: String
    var tint: Color = .secondary
    var dot: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(L10n.text(text))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(tint == .secondary ? Color.primary.opacity(0.06) : tint.opacity(0.14)))
    }
}

/// Compact pill button for secondary actions inside Settings cards (sound
/// previews, Change…, Show in Finder, Edit…).
struct SettingsChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension ButtonStyle where Self == SettingsChipButtonStyle {
    static var settingsChip: SettingsChipButtonStyle { SettingsChipButtonStyle() }
}
