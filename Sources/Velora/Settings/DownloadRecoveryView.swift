import SwiftUI

// Both surfaces render the same authoritative attempts and send only engine recovery commands.
struct DownloadRecoveryView: View {
    @ObservedObject private var state: DownloadState
    @State private var restarting: ModelDownload?
    private let kind: DownloadKind?

    init(state: DownloadState, kind: DownloadKind? = nil) {
        self.state = state
        self.kind = kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.m) {
            if !state.isCurrent {
                Text("Waiting for current download status…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.downloads.filter { kind == nil || $0.kind == kind }) { item in
                row(item)
            }
            if state.downloads.isEmpty {
                Text("Connecting to the model engine…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .alert("Restart Download?", isPresented: Binding(
            get: { restarting != nil },
            set: { if !$0 { restarting = nil } })) {
                Button("Restart Download", role: .destructive) {
                    if let item = restarting { state.request(item, .restart) }
                    restarting = nil
                }
                Button("Cancel", role: .cancel) { restarting = nil }
            } message: {
                Text("Discard this attempt’s incomplete files. Completed files and installed models stay. The engine checks ownership before restarting.")
            }
    }

    private func row(_ item: ModelDownload) -> some View {
        VStack(alignment: .leading, spacing: VeloraSpacing.s) {
            HStack {
                Text(item.kind == .stt ? "Speech model" : "Writing model")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(item.model.split(separator: "/").last.map(String.init) ?? item.model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(Self.phaseLabel(item))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let error = item.error {
                Text("\(error.category): \(error.message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if item.state == .downloading {
                if let fraction = item.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if item.state == .downloading || ((item.state == .retry_wait || item.state == .failed) && item.bytesReceived > 0) {
                Text(Self.byteLabel(item))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if item.state == .verifying || item.state == .loading || item.state == .queued {
                ProgressView().controlSize(.small)
            }
            if item.resume != .none, item.state != .ready {
                Text(Self.resumeLabel(item.resume))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if item.retryAllowed || item.restartAllowed {
                HStack {
                    if item.retryAllowed {
                        Button(item.kind == .cleanup ? "Retry Writing" : "Retry Now") {
                            state.request(item, .retry)
                        }
                        .disabled(!state.canAct(item, .retry))
                    }
                    if item.restartAllowed {
                        Button("Restart Download…") { restarting = item }
                            .disabled(!state.canAct(item, .restart))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private static func phaseLabel(_ item: ModelDownload) -> String {
        switch item.state {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying downloaded files…"
        case .loading: return "Loading model…"
        case .ready: return "Model adopted"
        case .failed: return "Model unavailable. Try again after fixing the error."
        case .retry_wait:
            guard let retryAt = item.retryAt else { return "Waiting to retry" }
            let time = Date(timeIntervalSince1970: retryAt)
                .formatted(date: .omitted, time: .standard)
            return "Retry \(item.retryIndex) scheduled for \(time)"
        }
    }

    private static func byteLabel(_ item: ModelDownload) -> String {
        let received = ByteCountFormatter.string(fromByteCount: item.bytesReceived, countStyle: .file)
        guard let total = item.bytesTotal else { return "\(received) received · total unknown" }
        return "\(received) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }

    private static func resumeLabel(_ resume: DownloadResume) -> String {
        switch resume {
        case .none: return ""
        case .partial: return "Resuming validated partial bytes"
        case .completed_files: return "Reusing verified completed files"
        case .file_restarted: return "This file restarted because partial resume was unsafe"
        }
    }
}
