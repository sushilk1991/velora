import AppKit
import SwiftUI

/// The system chooser names the receiving app or Shortcut. Merely generating
/// a result or importing a recipe never invokes a destination.
struct ResultShareButton: View {
    let text: String
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared

    var body: some View {
        ShareLink(item: text) {
            Label(L10n.text("Share…"), systemImage: "square.and.arrow.up")
        }
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(L10n.text("Choose an app or a Shortcut to receive this text."))
    }
}

struct MeetingRecapDraftButton: View {
    let text: String
    @ObservedObject private var interfaceLocale = InterfaceLocale.shared
    @State private var showing = false
    @State private var draft = ""

    var body: some View {
        Button(L10n.text("Draft recap…")) { draft = text; showing = true }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: VeloraSpacing.m) {
                    Text(L10n.text("Meeting recap")).font(.title2)
                    Text(L10n.text("Review the draft, then copy it or choose where to share it."))
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.body).frame(minHeight: 240)
                        .padding(VeloraSpacing.s)
                        .background(VeloraPanel.card)
                        .clipShape(RoundedRectangle(cornerRadius: VeloraRadius.tile))
                        .accessibilityLabel(L10n.text("Meeting recap"))
                    HStack {
                        Button(L10n.text("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft, forType: .string)
                        }
                        ResultShareButton(text: draft)
                        Spacer()
                        Button(L10n.text("Done")) { showing = false }.keyboardShortcut(.defaultAction)
                    }
                }.padding(VeloraSpacing.xl).frame(width: 600, height: 440)
            }
    }
}
