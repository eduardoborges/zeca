import AVFoundation
import Foundation

/// Faixa combinada da reuniao: mic + sistema mixados, alinhados pelos offsets.
/// Gerada sob demanda e cacheada como meeting.m4a na pasta da gravacao.
enum MeetingAudio {
    static func combinedURL(for recording: Recording) -> URL {
        recording.url.appendingPathComponent("meeting.m4a")
    }

    static func buildCombined(for recording: Recording) async throws -> URL {
        let out = combinedURL(for: recording)
        if FileManager.default.fileExists(atPath: out.path) { return out }

        let composition = AVMutableComposition()
        let offsets = recording.offsets
        for (url, offset) in [(recording.mic, offsets.mic), (recording.system, offsets.system)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: source,
                at: CMTime(seconds: offset, preferredTimescale: 600))
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Zeca", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the audio mix."])
        }
        try await export.export(to: out, as: .m4a)
        return out
    }
}

/// Player com play/pause, seek e progresso em tempo real.
@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var preparing = false
    @Published var scrubbing = false
    @Published var error: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL, autoplay: Bool) {
        stopTimer()
        player?.stop()
        do {
            let loaded = try AVAudioPlayer(contentsOf: url)
            loaded.delegate = self
            player = loaded
            duration = loaded.duration
            progress = 0
            error = nil
            isPlaying = false
            if autoplay { play() }
        } catch {
            player = nil
            duration = 0
            self.error = error.localizedDescription
        }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        player.currentTime = progress
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        progress = player?.currentTime ?? progress
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        player?.currentTime = clamped
        progress = clamped
    }

    func unload() {
        stopTimer()
        player?.stop()
        player = nil
        isPlaying = false
        progress = 0
        duration = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            self.progress = 0
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player, !self.scrubbing else { return }
                self.progress = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
