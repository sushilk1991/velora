import SwiftUI

/// A local draft: only Save applies the preview choices to the running app.
struct HUDPreviewView: View {
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var appearance = "system"
    @State private var words = false
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: reducedMotion)) { timeline in
                HStack(spacing: 12) {
                    Image(systemName: "mic.fill")
                    if words {
                        Text(L10n.text("These are provisional words…")).font(.system(size: 12)).lineLimit(1)
                    } else {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(0..<24) { index in
                                Capsule().fill(VeloraBrand.accent)
                                    .frame(width: 3, height: height(index, at: timeline.date))
                            }
                        }.frame(height: 24)
                    }
                    Text(L10n.text("0:08")).font(.system(size: 11).monospacedDigit())
                }
                .padding(.horizontal, 18).frame(height: 48)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.15)))
                .environment(\.colorScheme, appearance == "dark" ? .dark : appearance == "light" ? .light : systemScheme)
                .accessibilityLabel(L10n.text("Animated pill preview, microphone off"))
            }
            Text(L10n.text("Preview without using the microphone. Changes apply only when saved."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("Appearance"), selection: $appearance) {
                Text(L10n.text("System")).tag("system")
                Text(L10n.text("Light")).tag("light")
                Text(L10n.text("Dark")).tag("dark")
            }
            Toggle(L10n.text("Show words while speaking"), isOn: $words)
            HStack {
                Button(L10n.text("Discard changes"), action: reload)
                Button(L10n.text("Save")) {
                    model.appearance = appearance
                    model.showLiveWords = words
                    saved = true
                }
                if saved { Text(L10n.text("Saved")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: appearance) { _ in saved = false }
        .onChange(of: words) { _ in saved = false }
    }

    private func reload() {
        appearance = model.appearance
        words = model.showLiveWords
        saved = false
    }

    private func height(_ index: Int, at date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate * 4
        return 3 + CGFloat(abs(sin(phase + Double(index) * 0.7))) * 20
    }
}
