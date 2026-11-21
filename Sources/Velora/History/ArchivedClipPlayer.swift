import AVFoundation
import Foundation

/// Streams one audio file through `AVAudioEngine`.
///
/// This exists for the Ogg Opus clips the engine archives since 0.34:
/// `AVAudioPlayer` opens them, reports the right duration, then fails
/// `prepareToPlay()` and returns false from `play()` (checked on macOS 26 and
/// 27, at 16 kHz and 48 kHz). `AVAudioFile` reads those files fine, so they are
/// scheduled on a player node instead — decoded on the audio thread, never
/// loaded whole into memory.
final class StreamedClipPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let duration: TimeInterval

    init?(url: URL) {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        duration = rate > 0 ? Double(file.length) / rate : 0
        engine.attach(node)
        do {
            if #available(macOS 27.0, *) {
                try engine.connectNode(node, to: engine.mainMixerNode, format: file.processingFormat)
            } else {
                engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
            }
        } catch {
            NSLog("Velora: cannot route %@ through the audio engine (%@)", url.lastPathComponent, "\(error)")
            return nil
        }
        node.scheduleFile(file, at: nil)
    }

    func play() {
        do {
            try engine.start()
            if #available(macOS 27.0, *) {
                try node.playAudio()
            } else {
                node.play()
            }
        } catch {
            NSLog("Velora: streamed clip playback failed (%@)", "\(error)")
        }
    }

    func stop() {
        node.stop()
        engine.stop()
    }
}

/// Plays one archived dictation clip for History playback.
final class ArchivedClipPlayer {
    enum Route: Equatable {
        case avPlayer
        case engine
    }

    /// Which player a clip basename needs, before touching the file.
    static func route(forExtension ext: String) -> Route {
        ext.lowercased() == "ogg" ? .engine : .avPlayer
    }

    private enum Backing {
        case av(AVAudioPlayer)
        case streamed(StreamedClipPlayer)
    }

    let route: Route
    private let backing: Backing

    var duration: TimeInterval {
        switch backing {
        case let .av(player): return player.duration
        case let .streamed(player): return player.duration
        }
    }

    init?(url: URL) {
        if Self.route(forExtension: url.pathExtension) == .avPlayer,
           let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() {
            route = .avPlayer
            backing = .av(player)
            return
        }
        // Every Ogg clip lands here, and so does any WAV/FLAC AVAudioPlayer
        // declines; a file neither decoder can read yields no player at all.
        guard let player = StreamedClipPlayer(url: url) else { return nil }
        route = .engine
        backing = .streamed(player)
    }

    func play() {
        switch backing {
        case let .av(player): player.play()
        case let .streamed(player): player.play()
        }
    }

    func stop() {
        switch backing {
        case let .av(player): player.stop()
        case let .streamed(player): player.stop()
        }
    }
}
