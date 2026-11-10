import SwiftUI

/// A local draft: only Save applies the preview choices to the running app.
struct HUDPreviewView: View {
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
                        Text("These are provisional words…").font(.system(size: 12)).lineLimit(1)
                    } else {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(0..<24) { index in
                                Capsule().fill(VeloraBrand.accent)
                                    .frame(width: 3, height: height(index, at: timeline.date))
                            }
                        }.frame(height: 24)
                    }
                    Text("0:08").font(.system(size: 11).monospacedDigit())
                }
                .padding(.horizontal, 18).frame(height: 48)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.15)))
                .environment(\.colorScheme, appearance == "dark" ? .dark : appearance == "light" ? .light : systemScheme)
                .accessibilityLabel("Animated pill preview, microphone off")
            }
            Text("Preview without using the microphone. Changes apply only when saved.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle("Show words while speaking", isOn: $words)
            HStack {
                Button("Discard changes", action: reload)
                Button("Save") {
                    model.appearance = appearance
                    model.showLiveWords = words
                    saved = true
                }
                if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
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
