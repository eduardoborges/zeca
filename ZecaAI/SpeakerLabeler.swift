import FluidAudio
import Foundation
import SwiftUI

/// Diarizacao da trilha "Outros": separa os participantes da reuniao por voz
/// e rotula os turnos como "Falante 1", "Falante 2"...
/// Roda local (CoreML), pos-gravacao — onde a diarizacao e mais precisa.
@MainActor
final class SpeakerLabeler: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var error: String?

    private var diarizer: DiarizerManager?

    /// Relabela os turnos .others e regrava transcript.json. Devolve nil se nao mudou nada.
    func run(_ recording: Recording, turns: [Turn]) async -> [Turn]? {
        guard turns.contains(where: { $0.speaker == .others }) else { return nil }
        isRunning = true
        defer { isRunning = false }
        do {
            let diarizer = try await loadDiarizer()
            let systemURL = recording.system
            let offset = recording.offsets.system
            // Diarizacao e sincrona e pesada; fora do main actor.
            let segments = try await Task.detached(priority: .userInitiated) {
                let samples = try AudioConverter().resampleAudioFile(systemURL)
                return try diarizer.performCompleteDiarization(samples).segments
            }.value

            // speakerId -> "Falante N" na ordem de aparicao.
            var names: [String: String] = [:]
            for segment in segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds })
            where names[segment.speakerId] == nil {
                names[segment.speakerId] = "Speaker \(names.count + 1)"
            }
            guard !names.isEmpty else {
                error = "Diarization found no speech on the other participants' track."
                return nil
            }
            guard names.count > 1 else {
                error = "Diarization found a single speaker, so \"Others\" was kept."
                return nil
            }

            let labeled = turns.map { turn -> Turn in
                guard turn.speaker == .others else { return turn }
                var turn = turn
                turn.who = names[bestSpeaker(for: turn, offset: offset, in: segments) ?? ""]
                return turn
            }
            if let data = try? JSONEncoder().encode(labeled) {
                try? data.write(to: recording.transcriptURL)
            }
            return labeled
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Falante com maior sobreposicao de tempo com o turno.
    private func bestSpeaker(for turn: Turn, offset: TimeInterval, in segments: [TimedSpeakerSegment]) -> String? {
        var overlaps: [String: Double] = [:]
        for segment in segments {
            let start = Double(segment.startTimeSeconds) + offset
            let end = Double(segment.endTimeSeconds) + offset
            let overlap = min(turn.end, end) - max(turn.start, start)
            if overlap > 0 { overlaps[segment.speakerId, default: 0] += overlap }
        }
        return overlaps.max { $0.value < $1.value }?.key
    }

    private func loadDiarizer() async throws -> DiarizerManager {
        if let diarizer { return diarizer }
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        self.diarizer = diarizer
        return diarizer
    }
}
