import AppKit
import SwiftUI

enum SettingsLayoutMetrics {
    static let sectionSpacing: CGFloat = 18
}

/// Scrollable vertical canvas for every Settings tab. Forces overlay scrollbars
/// on its enclosing `NSScrollView` so switching between scrolling and
/// non-scrolling tabs never shifts card columns horizontally.
struct SettingsScrollCanvas<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, VeloraSpacing.xl)
            .background(OverlayScrollStyle())
        }
    }
}

/// Sets `scrollerStyle = .overlay` on the enclosing `NSScrollView` so macOS
/// "Always show scroll bars" doesn't narrow overflowing tabs by 15 pt and
/// cause layout jumps when switching tabs.
struct OverlayScrollStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        OverlayScrollAnchorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? OverlayScrollAnchorView)?.applyOverlayStyle()
    }
}

private final class OverlayScrollAnchorView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyOverlayStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOverlayStyle()
    }

    func applyOverlayStyle() {
        var current: NSView? = superview
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView {
                if scrollView.scrollerStyle != .overlay {
                    scrollView.scrollerStyle = .overlay
                }
                return
            }
            current = candidate.superview
        }
    }
}

/// Two equal-width columns that stack cleanly into one column when each column
/// would fall below `minimumColumnWidth`. Uses SwiftUI's `Layout` protocol
/// (mirroring `HomeColumns` in `HomeView.swift`) so columns measure at their
/// natural height inside a `ScrollView` without `GeometryReader` hacks.
struct SettingsColumns: Layout {
    var spacing: CGFloat = VeloraSpacing.l
    var stackSpacing: CGFloat = SettingsLayoutMetrics.sectionSpacing
    var minimumColumnWidth: CGFloat = 420

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(spacing, +)
        let height = frames(forWidth: width, subviews: subviews).map(\.maxY).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (subview, frame) in zip(subviews, frames(forWidth: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func frames(forWidth width: CGFloat, subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else {
            return stackedFrames(forWidth: width, subviews: subviews)
        }
        let available = max(width - spacing, 0)
        let columnWidth = (available / 2).rounded(.down)
        guard columnWidth >= minimumColumnWidth else {
            return stackedFrames(forWidth: width, subviews: subviews)
        }
        let trailingWidth = available - columnWidth
        let leftHeight = subviews[0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        let rightHeight = subviews[1].sizeThatFits(ProposedViewSize(width: trailingWidth, height: nil)).height
        return [
            CGRect(x: 0, y: 0, width: columnWidth, height: leftHeight),
            CGRect(x: columnWidth + spacing, y: 0, width: trailingWidth, height: rightHeight),
        ]
    }

    private func stackedFrames(forWidth width: CGFloat, subviews: Subviews) -> [CGRect] {
        var y: CGFloat = 0
        return subviews.map { subview in
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            defer { y += height + stackSpacing }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }
}

/// Convenience pair of left/right column stacks fed into `SettingsColumns`.
struct SettingsColumnPair<Left: View, Right: View>: View {
    private let left: Left
    private let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
    }

    var body: some View {
        SettingsColumns {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                left
            }
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                right
            }
        }
    }
}

/// Toggle row built on `GroupRow`, matching Dictionary's `Learning` card
/// (13 pt label, 11 pt sub-caption, small macOS switch, 42 pt minHeight).
struct SettingsToggleRow: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        GroupRow(label: L10n.text(title), sub: subtitle.map { L10n.text($0) }) {
            Toggle(L10n.text(title), isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

/// Expandable row inside a `GroupCard` that keeps `GroupRow`'s exact 14 pt
/// inset, 42 pt minimum height, and typography instead of SwiftUI's misaligned
/// default `DisclosureGroup` chrome.
struct SettingsDisclosureRow<Content: View>: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    let title: String
    var subtitle: String?
    private let content: Content
    @State private var isExpanded = false

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(VeloraMotion.quick) {
                    isExpanded.toggle()
                }
            } label: {
                GroupRow(label: L10n.text(title), sub: subtitle.map { L10n.text($0) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? L10n.text("Expanded") : L10n.text("Collapsed"))

            if isExpanded {
                GroupDivider()
                content
                    .padding(.horizontal, 14)
                    .padding(.vertical, VeloraSpacing.m)
            }
        }
    }
}

/// One selectable entry in a `CapsuleOptionMenu`.
struct CapsuleMenuItem<Value: Hashable> {
    let value: Value
    let title: String
    let isSeparatorBefore: Bool

    init(_ value: Value, title: String, separatorBefore: Bool = false) {
        self.value = value
        self.title = title
        self.isSeparatorBefore = separatorBefore
    }
}

/// Glass capsule chooser backed directly by AppKit `NSMenu.popUp(positioning:at:in:)`.
///
/// SwiftUI `Menu` with `.menuStyle(.button)` + a custom `ButtonStyle` drops
/// clicks inside `ScrollView`s and when the window floats over another app's
/// full-screen Space. Anchoring a real `NSMenu` to the button's `NSView` keeps
/// the exact 28 pt `.capsule` appearance while opening 100% reliably everywhere.
struct CapsuleOptionMenu<Value: Hashable>: View {
    let label: String
    let valueTitle: String
    var systemImage: String?
    let items: [CapsuleMenuItem<Value>]
    let selectedValue: Value?
    let onSelect: (Value) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var anchorView: NSView?

    private static var chevronSize: CGFloat { 9 }

    init(
        _ label: String,
        value: String,
        systemImage: String? = nil,
        selection: Binding<Value>,
        items: [CapsuleMenuItem<Value>]
    ) {
        self.label = label
        self.valueTitle = value
        self.systemImage = systemImage
        self.items = items
        self.selectedValue = selection.wrappedValue
        self.onSelect = { selection.wrappedValue = $0 }
    }

    init(
        _ label: String,
        title: String,
        systemImage: String? = nil,
        items: [CapsuleMenuItem<Value>],
        selected: Value? = nil,
        onSelect: @escaping (Value) -> Void
    ) {
        self.label = label
        self.valueTitle = title
        self.systemImage = systemImage
        self.items = items
        self.selectedValue = selected
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: presentMenu) {
            HStack(spacing: VeloraSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(valueTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: Self.chevronSize, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.capsule)
        .fixedSize()
        .background(MenuAnchorView(anchor: $anchorView))
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(valueTitle)
    }

    private func presentMenu() {
        guard isEnabled, let view = anchorView else { return }
        if let window = view.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
        let coordinator = PopupMenuCoordinator(items: items, onSelect: onSelect)
        let menu = NSMenu(title: label)
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            if item.isSeparatorBefore && index > 0 {
                menu.addItem(.separator())
            }
            let menuItem = NSMenuItem(
                title: item.title,
                action: #selector(PopupMenuCoordinator<Value>.picked(_:)),
                keyEquivalent: "")
            menuItem.target = coordinator
            menuItem.tag = index
            menuItem.isEnabled = true
            if let selectedValue, item.value == selectedValue {
                menuItem.state = .on
            }
            menu.addItem(menuItem)
        }
        // Keep the target alive until `popUp` finishes tracking synchronously.
        withExtendedLifetime(coordinator) {
            let origin = NSPoint(x: 0, y: view.bounds.height + 4)
            _ = menu.popUp(positioning: nil, at: origin, in: view)
        }
    }
}

private final class PopupMenuCoordinator<Value: Hashable>: NSObject {
    let items: [CapsuleMenuItem<Value>]
    let onSelect: (Value) -> Void

    init(items: [CapsuleMenuItem<Value>], onSelect: @escaping (Value) -> Void) {
        self.items = items
        self.onSelect = onSelect
    }

    @objc func picked(_ sender: NSMenuItem) {
        let index = sender.tag
        guard items.indices.contains(index) else { return }
        onSelect(items[index].value)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    @Binding var anchor: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { anchor = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if anchor !== nsView {
            DispatchQueue.main.async { anchor = nsView }
        }
    }
}
