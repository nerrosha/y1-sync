import Foundation
import AVFoundation
import Observation
import AppKit
import Y1SyncCore

/// Plays a file straight off the device so you can hear exactly what was
/// written — including its resized artwork and fetched lyrics.
@MainActor
@Observable
final class PlayerModel {
    private(set) var currentURL: URL?
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private(set) var lyrics: [LyricLine] = []
    private(set) var artwork: NSImage?
    private(set) var artworkSize: String?
    private(set) var loadError: String?

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// Index of the lyric line to highlight right now.
    var activeLyricIndex: Int? {
        LRC.activeIndex(of: lyrics, at: currentTime)
    }

    var hasLyrics: Bool { !lyrics.isEmpty }

    // No deinit cleanup: `ticker` is main-actor isolated and cannot be touched
    // from a nonisolated deinit. The timer holds only a weak self, and the
    // view calls stop() on disappear.

    func load(_ url: URL) {
        stop()
        currentURL = url
        loadError = nil
        lyrics = LRC.load(besideAudio: url)
        loadArtwork(from: url)

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
        } catch {
            player = nil
            duration = 0
            // A file that will not open here would not play on the device
            // either, which is itself useful to see.
            loadError = error.localizedDescription
        }
    }

    /// Read the cover straight out of the file's tags — the same place the
    /// player reads it from.
    private func loadArtwork(from url: URL) {
        artwork = nil
        artworkSize = nil
        guard let art = EmbeddedArtwork.read(from: url),
              let image = NSImage(data: art) else { return }
        artwork = image
        artworkSize = "\(Int(image.size.width))x\(Int(image.size.height))"
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTicking()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(time, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        lyrics = []
        artwork = nil
        artworkSize = nil
    }

    /// Lyrics need finer updates than a progress bar; 10 Hz keeps the
    /// highlighted line in step without noticeable cost.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying && self.isPlaying {
                    self.isPlaying = false
                    self.ticker?.invalidate()
                }
            }
        }
    }

    static func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}
