import AppKit
import SwiftUI

// Shared visual language for the settings window. Everything renders with
// solid colors — the offscreen snapshot renderer composites materials as
// blank surfaces — and every pane sits on the one canvas/card pair below
// (grouped Forms hide their own scroll background to reveal it), so the
// whole window reads as a single surface in both themes.

/// The settings window's canonical surfaces. Canvas is the window and pane
/// ground, card the elevated surface on top of it, raised one step further
/// (a sunk well on light). Defined as explicit sRGB values because no
/// public semantic NSColor gives one consistent answer across Forms,
/// ScrollViews, and the titlebar. Brand v2: warm ink on dark, warm paper
/// on light.
enum VeloraPanel {
    /// Picks `dark` under `.darkAqua`, `light` otherwise.
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func srgb(_ r: Int, _ g: Int, _ b: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }

    /// Ink (#161311 window) / paper (#faf8f5 window).
    static let canvasColor = dynamic(dark: srgb(22, 19, 17), light: srgb(250, 248, 245))
    /// Ink card (#201d1b) / paper card (#ffffff).
    static let cardColor = dynamic(dark: srgb(32, 29, 27), light: .white)
    /// Ink raised (#2c2927) / paper sunk (#f3f1ee): wells, code, inset fields.
    static let raisedColor = dynamic(dark: srgb(44, 41, 39), light: srgb(243, 241, 238))

    /// Glass sidebar fill, white 7 % on dark / white 55 % on light. Always
    /// drawn under the material so the sidebar survives the snapshot pipeline.
    static let sidebarColor = dynamic(
        dark: NSColor.white.withAlphaComponent(0.07),
        light: NSColor.white.withAlphaComponent(0.55))
    /// Sidebar border, white 10 % / white 80 %.
    static let sidebarLineColor = dynamic(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: NSColor.white.withAlphaComponent(0.80))
    /// Sidebar inner top highlight, white 14 % / white 90 %.
    static let sidebarHighlightColor = dynamic(
        dark: NSColor.white.withAlphaComponent(0.14),
        light: NSColor.white.withAlphaComponent(0.90))
    /// Selected sidebar row, white 14 % on dark / ink 9 % on light.
    static let sidebarSelectionColor = dynamic(
        dark: NSColor.white.withAlphaComponent(0.14),
        light: srgb(29, 26, 24, alpha: 0.09))
    /// Hairline for card borders and dividers, white 10 % / ink 10 %.
    static let hairlineColor = dynamic(
        dark: NSColor.white.withAlphaComponent(0.10),
        light: srgb(29, 26, 24, alpha: 0.10))
    /// Text on an accent-filled control: ink on dark (sky is light), white
    /// on light (sky-deep is dark).
    static let onAccentColor = dynamic(dark: srgb(22, 19, 17), light: .white)

    static let canvas = Color(nsColor: canvasColor)
    static let card = Color(nsColor: cardColor)
    static let raised = Color(nsColor: raisedColor)
    static let sidebar = Color(nsColor: sidebarColor)
    static let sidebarLine = Color(nsColor: sidebarLineColor)
    static let sidebarHighlight = Color(nsColor: sidebarHighlightColor)
    static let sidebarSelection = Color(nsColor: sidebarSelectionColor)
    static let hairline = Color(nsColor: hairlineColor)
    static let onAccent = Color(nsColor: onAccentColor)
}

/// Corner radii. Nested surfaces stay concentric (outer = inner + padding).
enum VeloraRadius {
    static let control: CGFloat = 6   // keycaps, chips, small buttons
    static let tile: CGFloat = 8      // icon tiles, thumbnails, rows
    static let row: CGFloat = 9       // sidebar rows
    static let card: CGFloat = 12     // cards and sheets
    static let sidebar: CGFloat = 14  // the floating glass sidebar
    static let capsule: CGFloat = 14  // 28 pt capsule buttons
    static let window: CGFloat = 18   // cosmetic only; AppKit owns the corners
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
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .fill(VeloraPanel.card))
        .overlay(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
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

/// How a `StatTile` colours its value.
enum StatEmphasis {
    case plain
    /// Tints the value with `VeloraBrand.accent` (the pane's one hero number).
    case accent
}

/// Hero metric tile: a 12 pt secondary label above a 26 pt bold tabular
/// value, on a card.
///
///     ┌──────────────────┐
///     │ words            │  12 pt secondary
///     │ 12,480           │  26 pt bold, monospaced digits
///     └──────────────────┘
struct StatTile: View {
    let value: String
    let label: String
    var emphasis: StatEmphasis = .plain

    init(value: String, label: String, emphasis: StatEmphasis = .plain) {
        self.value = value
        self.label = label
        self.emphasis = emphasis
    }

    /// Pre-v2 signature. The icon tile is gone; `symbol` and `color` are
    /// accepted so existing call sites compile, and ignored.
    init(symbol: String, color: Color, value: String, label: String) {
        self.init(value: value, label: label)
    }

    private var valueStyle: AnyShapeStyle {
        switch emphasis {
        case .plain: return AnyShapeStyle(.primary)
        case .accent: return AnyShapeStyle(VeloraBrand.accent)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.xs) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(valueStyle)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(VeloraSpacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .fill(VeloraPanel.card))
        .overlay(
            RoundedRectangle(cornerRadius: VeloraRadius.card, style: .continuous)
                .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
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
                        RoundedRectangle(cornerRadius: VeloraRadius.control, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: VeloraRadius.control, style: .continuous)
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

// MARK: - Brand v2 window chrome

/// Sidebar and detail geometry shared by the main and Settings windows.
/// One row height, one symbol well, one rail inset, one top clearance, one
/// selection fill — MainSidebar and SettingsSidebar cannot drift. Title
/// baseline is `detailTop` + a `PaneHeader` (`titleHeight`); both shells
/// wrap their detail column in `WindowShell` so those numbers live once.
enum WindowShellMetrics {
    /// Sidebar width including its rail inset on each side.
    static let sidebarWidth: CGFloat = 200
    /// Room left at the top of the glass sidebar for the traffic lights,
    /// which sit inside it under `.fullSizeContentView`.
    static let trafficLightClearance: CGFloat = 52
    /// Gap between the sidebar's outer edge and the detail column.
    static let sidebarGap: CGFloat = 16
    static let detailTop: CGFloat = 18
    static let detailTrailing: CGFloat = 24
    static let detailBottom: CGFloat = 22
    static let detailLeading: CGFloat = 20
    /// Grouped forms centre themselves at any width; capping them keeps the
    /// Meetings form hugging the pane title instead of floating mid-window.
    static let formMaxWidth: CGFloat = 740
    /// Finder/Notes-style rail row (MainSidebar and SettingsSidebar).
    static let rowHeight: CGFloat = 32
    /// 22 pt well for the monochrome symbol and the coloured IconTile.
    static let symbolWell: CGFloat = 22
    /// SF Symbol point size inside the monochrome well.
    static let symbolSize: CGFloat = 16
    /// Inset inside and around the glass rail.
    static let railInset: CGFloat = VeloraSpacing.s
    /// `PaneHeader` height — both shells place this under `detailTop`.
    static let titleHeight: CGFloat = 36

    /// Room above the first rail row: clearance minus the inner inset
    /// `FloatingSidebar` already applies.
    ///
    ///     window top
    ///       ├ outer railInset
    ///       ├ inner railInset
    ///       ├ sidebarTopClearance  ← this
    ///       └ first row
    static var sidebarTopClearance: CGFloat {
        trafficLightClearance - railInset
    }

    /// Detail column leading: form inset + gap, minus the rail's outer inset.
    static var detailColumnLeading: CGFloat {
        detailLeading + sidebarGap - railInset
    }
}

/// The one chrome both shell windows compose: glass sidebar on the left,
/// padded detail column on the right, glow + canvas behind. Callers put a
/// `PaneHeader` at the top of `detail` so the title baseline is identical
/// by construction, not by copying padding numbers.
struct WindowShell<Sidebar: View, Detail: View>: View {
    private let sidebar: Sidebar
    private let detail: Detail

    init(
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.sidebar = sidebar()
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: WindowShellMetrics.sidebarWidth)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, WindowShellMetrics.detailTop)
                .padding(.trailing, WindowShellMetrics.detailTrailing)
                .padding(.bottom, WindowShellMetrics.detailBottom)
                .padding(.leading, WindowShellMetrics.detailColumnLeading)
        }
        .background(WindowGlow())
        .background(VeloraPanel.canvas)
        .ignoresSafeArea()
    }
}

/// Empty band at the top of a glass rail so the first row clears the
/// traffic lights sitting inside `.fullSizeContentView`.
struct SidebarTopSpace: View {
    var body: some View {
        Color.clear.frame(height: WindowShellMetrics.sidebarTopClearance)
    }
}

/// Shared row chrome: one height, one horizontal inset, one selection fill.
/// Main rows drop a monochrome symbol into this; Settings rows drop a
/// coloured `IconTile` — the one deliberate difference.
struct SidebarRowFrame<Content: View>: View {
    let selected: Bool
    private let content: Content

    init(selected: Bool, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, WindowShellMetrics.railInset)
            .frame(height: WindowShellMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous)
                    .fill(selected ? VeloraPanel.sidebarSelection : .clear))
            .contentShape(
                RoundedRectangle(cornerRadius: VeloraRadius.row, style: .continuous))
    }
}

/// The window's ambient glow: a sky radial at the top-left and an apricot
/// radial at the bottom-right, placed behind all window content. The
/// opacities differ per theme (sky 22 % dark / 18 % light, apricot 16 % /
/// 14 %): ink swallows a tint that paper shows, so dark runs stronger.
///
///     ┌────────────────────────┐
///     │ ◜ sky                  │
///     │                        │
///     │                apricot ◞│
///     └────────────────────────┘
struct WindowGlow: View {
    @Environment(\.colorScheme) private var colorScheme

    private static let skyOpacityDark = 0.22
    private static let skyOpacityLight = 0.18
    private static let apricotOpacityDark = 0.16
    private static let apricotOpacityLight = 0.14
    /// Radius as a fraction of the window's longer side.
    private static let reach = 0.65

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            let radius = max(geometry.size.width, geometry.size.height) * Self.reach
            ZStack {
                RadialGradient(
                    colors: [
                        VeloraBrand.sky.color.opacity(
                            isDark ? Self.skyOpacityDark : Self.skyOpacityLight),
                        .clear,
                    ],
                    center: .topLeading, startRadius: 0, endRadius: radius)
                RadialGradient(
                    colors: [
                        VeloraBrand.apricot.color.opacity(
                            isDark ? Self.apricotOpacityDark : Self.apricotOpacityLight),
                        .clear,
                    ],
                    center: .bottomTrailing, startRadius: 0, endRadius: radius)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The floating glass sidebar: inset 8 pt on every side, radius 14, a
/// translucent fill under the material (materials render blank offscreen,
/// see docs/DESIGN.md §3), hairline border, inner top highlight and a soft
/// shadow. The caller fills it with `SidebarRow`s.
///
///     ┌ window ──────────────────────┐
///     │ ┌ 8 pt ┐                     │
///     │ │ ▒▒▒▒ │  ← glass, radius 14 │
///     │ │ ▒row▒ │                    │
///     │ │ ▒▒▒▒ │                     │
///     │ └──────┘                     │
///     └──────────────────────────────┘
struct FloatingSidebar<Content: View>: View {
    private let content: Content

    private static var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VeloraRadius.sidebar, style: .continuous)
    }

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(WindowShellMetrics.railInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Self.shape.fill(VeloraPanel.sidebar))
        .modifier(SidebarGlass())
        .overlay(Self.shape.strokeBorder(VeloraPanel.sidebarLine, lineWidth: 1))
        .overlay(
            // Inner top highlight: a 1 pt stroke that fades out by mid-height.
            Self.shape.strokeBorder(
                LinearGradient(
                    colors: [VeloraPanel.sidebarHighlight, .clear],
                    startPoint: .top, endPoint: .center),
                lineWidth: 1)
            .padding(1))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        .padding(WindowShellMetrics.railInset)
    }
}

/// Liquid glass behind the sidebar on macOS 26; a no-op on earlier systems,
/// where the translucent fill alone carries the look.
private struct SidebarGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: VeloraRadius.sidebar, style: .continuous))
        } else {
            content
        }
    }
}

/// One sidebar entry, Finder/Notes style: a monochrome SF Symbol (accent
/// when selected, secondary otherwise) and a 13 pt title on a 32 pt row.
/// `trailing` is for a hint such as the "⌘," keycap.
///
///     ┌──────────────────────────┐ 32 pt, radius 9
///     │ ◎  General          ⌘,   │
///     └──────────────────────────┘
struct SidebarRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let selected: Bool
    @ViewBuilder var trailing: Trailing

    private var symbolStyle: AnyShapeStyle {
        selected ? AnyShapeStyle(VeloraBrand.accent) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        SidebarRowFrame(selected: selected) {
            HStack(spacing: VeloraSpacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: WindowShellMetrics.symbolSize, weight: .medium))
                    .foregroundStyle(symbolStyle)
                    .frame(
                        width: WindowShellMetrics.symbolWell,
                        height: WindowShellMetrics.symbolWell)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

extension SidebarRow where Trailing == EmptyView {
    init(symbol: String, title: String, selected: Bool) {
        self.init(symbol: symbol, title: title, selected: selected) { EmptyView() }
    }
}

/// A pane's 22 pt bold title with tightened tracking.
struct PaneTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .tracking(-0.4)
            .lineLimit(1)
    }
}

/// Pane header: title on the left, controls on the right, 36 pt tall.
///
///     Dictation                        [ Reset ] [ Test ]   36 pt
struct PaneHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: VeloraSpacing.m) {
            PaneTitle(title: title)
            Spacer(minLength: VeloraSpacing.m)
            trailing
        }
        .frame(height: WindowShellMetrics.titleHeight)
    }
}

extension PaneHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A serif headline (the system serif, New York, via `design: .serif`)
/// whose closing full stop is drawn in the warm accent. Pass the sentence
/// WITHOUT its full stop; the view appends it.
///
///     Say it once. It's already typed●   ← ● is apricot
struct SerifHeadline: View {
    enum Size {
        case standard
        case hero

        var points: CGFloat {
            switch self {
            case .standard: return 30
            case .hero: return 34
            }
        }
    }

    let text: String
    var size: Size = .standard

    init(_ text: String, size: Size = .standard) {
        self.text = text
        self.size = size
    }

    var body: some View {
        (Text(text) + Text(".").foregroundStyle(VeloraBrand.warm))
            .font(.system(size: size.points, weight: .regular, design: .serif))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Tahoe grouped card for use outside a `Form`: an optional uppercase
/// section header above (with an optional trailing link), a radius-12 card
/// with a hairline border holding `GroupRow`s separated by `GroupDivider`s,
/// and an optional footer below.
///
///     SECTION               Link   11.5 pt semibold uppercase · 12 pt link
///     ┌───────────────────────────┐
///     │ Label            [toggle] │  GroupRow
///     │   ├──────────────────────┤ │  GroupDivider (inset 14)
///     │ Label            [popup]  │
///     └───────────────────────────┘
///     Footer note.                  11 pt tertiary
struct GroupCard<Content: View>: View {
    /// A link on the header's trailing edge ("Open History").
    typealias HeaderLink = (title: String, action: () -> Void)

    private let header: String?
    private let headerLink: HeaderLink?
    private let footer: String?
    private let content: Content

    private static var labelInset: CGFloat { 14 }

    init(
        header: String? = nil, headerLink: HeaderLink? = nil, footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.headerLink = headerLink
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            if let header {
                HStack(alignment: .firstTextBaseline) {
                    Text(header)
                        .textCase(.uppercase)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let headerLink {
                        Spacer(minLength: VeloraSpacing.s)
                        Button(headerLink.title, action: headerLink.action)
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(VeloraBrand.link)
                    }
                }
                .padding(.horizontal, Self.labelInset)
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
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.labelInset)
            }
        }
    }
}

/// Hairline between two `GroupRow`s, inset 14 pt from the leading edge so
/// it aligns with the row labels.
struct GroupDivider: View {
    var body: some View {
        CardDivider()
            .padding(.leading, 14)
    }
}

/// One row of a `GroupCard`: 13 pt label with an optional 11 pt secondary
/// sub-caption, and a trailing control. At least 42 pt tall.
struct GroupRow<Trailing: View>: View {
    let label: String
    var sub: String?
    @ViewBuilder var trailing: Trailing

    private static var minHeight: CGFloat { 42 }
    private static var inset: CGFloat { 14 }

    var body: some View {
        HStack(alignment: .center, spacing: VeloraSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                if let sub {
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, VeloraSpacing.s)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .leading)
    }
}

extension GroupRow where Trailing == EmptyView {
    init(label: String, sub: String? = nil) {
        self.init(label: label, sub: sub) { EmptyView() }
    }
}

/// 28 pt glass capsule: `primary` at 10 % (16 % pressed), hairline border,
/// 12 pt label.
struct CapsuleButtonStyle: ButtonStyle {
    private static var height: CGFloat { 28 }
    private static var fillOpacity: Double { 0.10 }
    private static var pressedOpacity: Double { 0.16 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, VeloraSpacing.m)
            .frame(height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? Self.pressedOpacity : Self.fillOpacity)))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous)
                    .strokeBorder(VeloraPanel.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous))
    }
}

/// 28 pt primary capsule: accent fill (sky on dark, sky-deep on light) with
/// ink / white text, 12 pt semibold.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    private static var height: CGFloat { 28 }
    private static var pressedOpacity: Double { 0.85 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(VeloraPanel.onAccent)
            .padding(.horizontal, VeloraSpacing.m)
            .frame(height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous)
                    .fill(VeloraBrand.accent)
                    .opacity(configuration.isPressed ? Self.pressedOpacity : 1))
            .contentShape(RoundedRectangle(cornerRadius: VeloraRadius.capsule, style: .continuous))
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    /// `.buttonStyle(.capsule)`
    static var capsule: CapsuleButtonStyle { CapsuleButtonStyle() }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    /// `.buttonStyle(.primaryCapsule)`
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
}
