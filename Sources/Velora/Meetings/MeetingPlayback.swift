import AVFoundation
import Combine
import SwiftUI

enum MeetingAudioTrack: String, CaseIterable, Identifiable {
    case microphone, system, recording
    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .system: return "Mac audio"
        case .recording: return "Recording"
        }
    }
    func contains(_ speaker: MeetingSpeaker) -> Bool {
        switch self {
        case .microphone: return speaker == .me
        case .system: return speaker.isRemote && speaker != .recording
        case .recording: return speaker == .recording
        }
    }
}

/// The pane and notes window each own a player. All state is main-thread
/// owned, and neither a selection change nor deletion can leave audio playing.
final class MeetingAudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tracks: [MeetingAudioTrack] = []
    @Published private(set) var track: MeetingAudioTrack = .system
    @Published private(set) var isPlaying = false
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var error: String?
    private(set) var meetingID: String?

    private let store: MeetingStore
    private var record: MeetingRecord?
    private var player: AVAudioPlayer?
    private var playingURL: URL?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(store: MeetingStore) {
        self.store = store
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: .veloraMeetingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let id = self.meetingID else { return }
            self.configure(self.store.recordMetadata(id: id))
        }
    }

    deinit {
        timer?.invalidate()
        player?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func configure(_ record: MeetingRecord?) {
        let changed = self.record?.id != record?.id || self.record?.micPath != record?.micPath
            || self.record?.systemPath != record?.systemPath
        if changed { stop() }
        self.record = record
        meetingID = record?.id
        let available: [MeetingAudioTrack] = record?.isImported == true ? [.recording] : [.microphone, .system]
        tracks = record?.status == .recording ? [] : available.filter { url(for: $0) != nil }
        if !tracks.contains(track) {
            stop()
            track = tracks.contains(.system) ? .system : (tracks.first ?? .system)
        }
        if tracks.isEmpty { stop() }
        if changed { error = nil }
    }

    func selectTrack(_ value: MeetingAudioTrack) {
        guard tracks.contains(value), value != track else { return }
        let time = position
        stop()
        track = value
        if prepare() { seek(seconds: min(time, duration), resume: false) }
    }

    func toggle() {
        if isPlaying { pause(); return }
        guard prepare(), let player else { return }
        if player.currentTime >= player.duration { player.currentTime = 0 }
        guard player.play() else { fail("This recording could not be played."); return }
        isPlaying = true
        error = nil
        startTimer()
    }

    func play(_ segment: MeetingSegment) {
        guard segment.meetingID == meetingID else { return }
        let desired: MeetingAudioTrack = record?.isImported == true ? .recording
            : (segment.speaker == .me ? .microphone : .system)
        guard tracks.contains(desired) else {
            pause()
            error = "The audio for this transcript passage is no longer available."
            return
        }
        if track != desired { stop(); track = desired }
        guard prepare(), let target = Self.seekTime(milliseconds: segment.startMs, duration: duration) else {
            pause()
            error = "This passage is outside the retained recording."
            return
        }
        seek(seconds: target, resume: true)
    }

    func seek(seconds: TimeInterval, resume: Bool? = nil) {
        guard seconds.isFinite, prepare(), let player else { return }
        let shouldPlay = resume ?? isPlaying
        player.currentTime = max(0, min(seconds, duration))
        position = player.currentTime
        if shouldPlay {
            guard player.play() else { fail("This recording could not be played."); return }
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        position = player?.currentTime ?? position
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        timer?.invalidate()
        timer = nil
        isPlaying = false
        position = 0
        duration = 0
    }

    func activeSegment(in segments: [MeetingSegment]) -> Int64? {
        guard isPlaying else { return nil }
        let milliseconds = Int(position * 1_000)
        return segments.first {
            track.contains($0.speaker) && $0.startMs <= milliseconds && $0.endMs > milliseconds
        }?.id
    }

    static func seekTime(milliseconds: Int, duration: TimeInterval) -> TimeInterval? {
        let seconds = Double(milliseconds) / 1_000
        guard milliseconds >= 0, duration.isFinite, duration > 0, seconds < duration else { return nil }
        return seconds
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds < Double(Int.max) else { return "0:00" }
        let value = max(0, Int(seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func url(for track: MeetingAudioTrack) -> URL? {
        guard let record else { return nil }
        let relative = track == .microphone ? record.micPath : record.systemPath
        guard relative?.split(separator: "/").first.map(String.init) == record.id,
              let url = store.audioURL(relativePath: relative),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func prepare() -> Bool {
        guard let url = url(for: track) else {
            fail("This recording's audio is no longer available.")
            return false
        }
        if player != nil, playingURL == url { return true }
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            guard newPlayer.duration.isFinite, newPlayer.duration > 0 else {
                fail("This recording contains no playable audio.")
                return false
            }
            newPlayer.delegate = self
            newPlayer.prepareToPlay()
            player = newPlayer
            playingURL = url
            duration = newPlayer.duration
            error = nil
            return true
        } catch {
            fail("This recording could not be opened. Its audio may be missing or damaged.")
            return false
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            guard self.url(for: self.track) == self.playingURL else {
                self.fail("This recording's audio is no longer available.")
                return
            }
            self.position = player.currentTime
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        pause()
        position = flag ? duration : position
        if !flag { error = "Playback stopped before the recording finished." }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        fail("This recording could not be decoded.")
    }
}

struct MeetingPlaybackControls: View {
    @ObservedObject var playback: MeetingAudioPlayback

    var body: some View {
        GroupCard(header: "Recording") {
            VStack(alignment: .leading, spacing: VeloraSpacing.s) {
                if !playback.tracks.isEmpty {
                    HStack {
                        Button(action: playback.toggle) {
                            Label(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.capsule)
                        Picker("Audio track", selection: Binding(
                            get: { playback.track }, set: { playback.selectTrack($0) })) {
                            ForEach(playback.tracks) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        Spacer()
                        Text("\(MeetingAudioPlayback.clock(playback.position)) / \(MeetingAudioPlayback.clock(playback.duration))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if playback.duration > 0 {
                        Slider(value: Binding(get: { playback.position }, set: { playback.seek(seconds: $0) }),
                               in: 0...playback.duration)
                            .accessibilityLabel("Recording position")
                    }
                    Text("Click a transcript timestamp to hear that passage.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No retained audio is available for playback.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = playback.error {
                    Text(error).font(.caption).foregroundStyle(VeloraStatus.warningText)
                }
            }
            .padding(14)
        }
    }
}

struct MeetingPlayableTranscriptCard: View {
    @ObservedObject var loader: MeetingTranscriptLoader
    @ObservedObject var playback: MeetingAudioPlayback

    var body: some View {
        MeetingTranscriptCard(loader: loader, onSeek: { playback.play($0) },
                              activeSegmentID: playback.activeSegment(in: loader.segments ?? []))
    }
}
