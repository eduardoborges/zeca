import FluidAudio
import Foundation

/// A transcricao sempre detecta o idioma falado; nao ha configuracao.
enum LanguageSetting {
    static var code: String? { nil }
}

enum Speaker: String, Codable {
    case me       // trilha do microfone
    case others   // trilha do sistema

    var label: String { self == .me ? "You" : "Others" }
}

/// Um bloco contiguo de fala de um lado da conversa.
struct Turn: Codable, Identifiable, Hashable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Rotulo da diarizacao ("Falante 1", ...) para turnos de .others. Opcional: JSONs antigos nao tem.
    var who: String?
    var id: String { "\(speaker.rawValue)-\(start)" }

    var label: String { who ?? speaker.label }
}

extension Turn {
    /// Converte texto colado (WebVTT do Zoom ou linhas "Nome: fala") em turnos.
    /// Todo turno importado e .others com o nome em `who`; nao ha trilha de microfone.
    /// Sem timestamp na fonte, um relogio sintetico de 1s so garante ordem e ids unicos.
    static func parse(_ text: String) -> [Turn] {
        var turns: [Turn] = []
        var cueStart: TimeInterval?
        var cueEnd: TimeInterval?
        var clock: TimeInterval = 0

        // "00:01:23.500", "01:23,500" ou "01:23" -> segundos
        func seconds(_ stamp: String) -> TimeInterval? {
            let parts = stamp.replacingOccurrences(of: ",", with: ".")
                .split(separator: ":").map(String.init)
            guard (1...3).contains(parts.count) else { return nil }
            var total: TimeInterval = 0
            for part in parts {
                guard let value = Double(part) else { return nil }
                total = total * 60 + value
            }
            return total
        }

        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || Int(line) != nil { continue }
            if line.contains("-->") {
                let stamps = line.components(separatedBy: "-->")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                cueStart = stamps.first.flatMap(seconds)
                cueEnd = stamps.count > 1 ? seconds(stamps[1]) : nil
                continue
            }
            // txt do Zoom: "00:03:12 Nome: fala" (timestamp solto no comeco da linha)
            if let space = line.firstIndex(of: " "),
               let stamp = seconds(String(line[..<space]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) {
                cueStart = stamp
                cueEnd = nil
                line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
            }
            var who: String?
            if let colon = line.range(of: ": "),
               line.distance(from: line.startIndex, to: colon.lowerBound) <= 40 {
                who = String(line[..<colon.lowerBound])
                line = String(line[colon.upperBound...])
            }
            guard !line.isEmpty else { continue }
            if who == nil, let last = turns.last {
                // linha sem "Nome:" e continuacao do turno anterior (cue de varias linhas)
                turns[turns.count - 1] = Turn(speaker: last.speaker, start: last.start,
                                              end: cueEnd ?? last.end,
                                              text: last.text + " " + line, who: last.who)
            } else {
                let start = cueStart ?? clock
                turns.append(Turn(speaker: .others, start: start, end: cueEnd ?? start,
                                  text: line, who: who))
            }
            clock = max(clock, cueEnd ?? cueStart ?? clock) + 1
            cueStart = nil
            cueEnd = nil
        }
        return turns
    }
}

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var status: String?
    /// Fracao [0,1] quando ha progresso mensuravel; nil = indeterminado.
    @Published private(set) var progress: Double?
    @Published var error: String?

    private var manager: AsrManager?
    private var managerTask: Task<AsrManager, Error>?

    /// Transcreve as duas trilhas com o Parakeet e devolve a conversa intercalada.
    /// Grava o resultado em transcript.json dentro da pasta da gravacao.
    func run(_ recording: Recording) async -> [Turn]? {
        error = nil
        do {
            var turns: [Turn] = []
            let offsets = recording.offsets
            let tracks = [
                (recording.mic, Speaker.me, offsets.mic),
                (recording.system, Speaker.others, offsets.system),
            ].filter { FileManager.default.fileExists(atPath: $0.0.path) }

            // Reuniao importada (sem audio): nada a transcrever, e o transcript
            // colado nao pode ser sobrescrito por um JSON vazio.
            guard !tracks.isEmpty else {
                status = nil
                return nil
            }

            let manager = try await loadManager()
            let language = LanguageSetting.code.flatMap(Language.init(rawValue:))
            for (url, speaker, offset) in tracks {
                status = "Transcribing \(speaker.label)..."
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(url, decoderState: &state, language: language)
                turns += Self.turns(from: result, speaker: speaker, offset: offset)
            }

            turns.sort { $0.start < $1.start }
            if let data = try? JSONEncoder().encode(turns) {
                try? data.write(to: recording.transcriptURL)
            }
            status = nil
            progress = nil
            return turns
        } catch {
            self.error = error.localizedDescription
            status = nil
            progress = nil
            return nil
        }
    }

    /// Tambem usado pela LiveSession para transcrever durante a gravacao.
    /// Reentrante: chamadas simultaneas (ao vivo + offline) compartilham o mesmo carregamento,
    /// e o status e limpo aqui mesmo — quem chama nao precisa (e nao deve) cuidar disso.
    func loadManager() async throws -> AsrManager {
        if let manager { return manager }
        if let managerTask { return try await managerTask.value }
        let task = Task { [weak self] () -> AsrManager in
            await MainActor.run { self?.status = "Preparing Parakeet..." }
            // O handler vem de uma fila qualquer; salta pro main actor antes de tocar o @Published.
            let models = try await AsrModels.downloadAndLoad(version: .v3) { [weak self] update in
                Task { @MainActor in
                    self?.status = Self.describe(update.phase)
                    self?.progress = update.fractionCompleted
                }
            }
            await MainActor.run {
                self?.status = "Loading the model..."
                self?.progress = nil
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        managerTask = task
        defer {
            status = nil
            progress = nil
            managerTask = nil
        }
        let loaded = try await task.value
        manager = loaded
        return loaded
    }

    private static func describe(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Checking model files..."
        case .downloading(let done, let total):
            return "Downloading Parakeet — \(done) of \(total) files"
        case .compiling(let model):
            return "Compiling \(model) for the Neural Engine..."
        }
    }

    /// Agrupa palavras em turnos, cortando onde houver silencio.
    /// ponytail: gap fixo de 1.2s; vira parametro se na pratica cortar mal.
    static func turns(
        from result: ASRResult, speaker: Speaker, offset: TimeInterval, gap: TimeInterval = 1.2
    ) -> [Turn] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            guard !result.text.isEmpty else { return [] }
            return [Turn(speaker: speaker, start: offset, end: offset + result.duration, text: result.text)]
        }

        var turns: [Turn] = []
        var words: [String] = []
        var start = 0.0
        var end = 0.0

        for word in buildWordTimings(from: timings) {
            if !words.isEmpty, word.startTime - end > gap {
                turns.append(Turn(speaker: speaker, start: start + offset, end: end + offset,
                                  text: words.joined(separator: " ")))
                words = []
            }
            if words.isEmpty { start = word.startTime }
            words.append(word.word)
            end = word.endTime
        }
        if !words.isEmpty {
            turns.append(Turn(speaker: speaker, start: start + offset, end: end + offset,
                              text: words.joined(separator: " ")))
        }
        return turns
    }
}
