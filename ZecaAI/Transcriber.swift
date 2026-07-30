import FluidAudio
import Foundation
import WhisperKit

/// Catalogo de modelos, mesmo do Hex.
struct AsrModelInfo: Identifiable, Hashable {
    enum Kind: Hashable {
        case parakeet(AsrModelVersion)
        case whisper(String) // nome do modelo no repo whisperkit-coreml
    }

    let id: String
    let name: String
    let languages: String
    let accuracyStars: Int
    let speedStars: Int
    let storage: String
    let kind: Kind

    static let catalog: [AsrModelInfo] = [
        AsrModelInfo(id: "parakeet-v3", name: "Parakeet TDT v3", languages: "25 idiomas",
                     accuracyStars: 5, speedStars: 5, storage: "650 MB", kind: .parakeet(.v3)),
        AsrModelInfo(id: "parakeet-v2", name: "Parakeet TDT v2", languages: "Só inglês",
                     accuracyStars: 5, speedStars: 5, storage: "650 MB", kind: .parakeet(.v2)),
        AsrModelInfo(id: "whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", languages: "99 idiomas",
                     accuracyStars: 4, speedStars: 4, storage: "626 MB",
                     kind: .whisper("openai_whisper-large-v3-v20240930_626MB")),
        AsrModelInfo(id: "whisper-large-v3", name: "Whisper Large v3", languages: "99 idiomas",
                     accuracyStars: 5, speedStars: 2, storage: "1,5 GB",
                     kind: .whisper("openai_whisper-large-v3-v20240930")),
        AsrModelInfo(id: "whisper-base", name: "Whisper Base", languages: "99 idiomas",
                     accuracyStars: 3, speedStars: 3, storage: "140 MB",
                     kind: .whisper("openai_whisper-base")),
        AsrModelInfo(id: "whisper-tiny", name: "Whisper Tiny", languages: "99 idiomas",
                     accuracyStars: 2, speedStars: 4, storage: "73 MB",
                     kind: .whisper("openai_whisper-tiny")),
    ]

    static var selected: AsrModelInfo {
        let id = UserDefaults.standard.string(forKey: "asrModel") ?? "parakeet-v3"
        return catalog.first { $0.id == id } ?? catalog[0]
    }

    /// Versao Parakeet usada pela transcricao ao vivo (streaming exige Parakeet).
    static var liveParakeetVersion: AsrModelVersion {
        if case .parakeet(let version) = selected.kind { return version }
        return .v3
    }
}

/// Idioma configurado ("auto" = detectar). Codigos ISO ("pt", "en"...).
enum LanguageSetting {
    static var code: String? {
        let raw = UserDefaults.standard.string(forKey: "asrLanguage") ?? "auto"
        return raw == "auto" ? nil : raw
    }
}

enum Speaker: String, Codable {
    case me       // trilha do microfone
    case others   // trilha do sistema

    var label: String { self == .me ? "Voce" : "Outros" }
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

@MainActor
final class Transcriber: ObservableObject {
    @Published private(set) var status: String?
    /// Fracao [0,1] quando ha progresso mensuravel; nil = indeterminado.
    @Published private(set) var progress: Double?
    @Published var error: String?

    private var managers: [AsrModelVersion: AsrManager] = [:]
    private var managerTask: Task<AsrManager, Error>?
    private var whispers: [String: WhisperKit] = [:]
    private var whisperTask: Task<WhisperKit, Error>?

    /// Transcreve as duas trilhas com o modelo configurado e devolve a conversa intercalada.
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

            let model = AsrModelInfo.selected
            switch model.kind {
            case .whisper(let name):
                let pipe = try await loadWhisper(name)
                for (url, speaker, offset) in tracks {
                    status = "Transcrevendo \(speaker.label) com o \(model.name)..."
                    turns += try await Self.whisperTurns(pipe: pipe, url: url, speaker: speaker, offset: offset)
                }
            case .parakeet(let version):
                let manager = try await loadManager(version: version)
                let language = LanguageSetting.code.flatMap(Language.init(rawValue:))
                for (url, speaker, offset) in tracks {
                    status = "Transcrevendo \(speaker.label)..."
                    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                    let result = try await manager.transcribe(url, decoderState: &state, language: language)
                    turns += Self.turns(from: result, speaker: speaker, offset: offset)
                }
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

    /// Whisper devolve segmentos com inicio/fim — viram turnos direto.
    private static func whisperTurns(
        pipe: WhisperKit, url: URL, speaker: Speaker, offset: TimeInterval
    ) async throws -> [Turn] {
        var options = DecodingOptions()
        options.task = .transcribe
        options.skipSpecialTokens = true
        if let code = LanguageSetting.code {
            options.language = code
        } else {
            options.detectLanguage = true
        }
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Turn(speaker: speaker,
                        start: Double(segment.start) + offset,
                        end: Double(segment.end) + offset,
                        text: text)
        }
    }

    /// Mesmo padrao reentrante do loadManager.
    private func loadWhisper(_ name: String) async throws -> WhisperKit {
        if let cached = whispers[name] { return cached }
        if let whisperTask { return try await whisperTask.value }
        let task = Task { [weak self] () -> WhisperKit in
            await MainActor.run { self?.status = "Baixando/carregando o Whisper (uma vez por modelo)..." }
            return try await WhisperKit(WhisperKitConfig(model: name))
        }
        whisperTask = task
        defer {
            status = nil
            progress = nil
            whisperTask = nil
        }
        let pipe = try await task.value
        whispers[name] = pipe
        return pipe
    }

    /// Tambem usado pela LiveSession para transcrever durante a gravacao.
    /// Reentrante: chamadas simultaneas (ao vivo + offline) compartilham o mesmo carregamento,
    /// e o status e limpo aqui mesmo — quem chama nao precisa (e nao deve) cuidar disso.
    func loadManager(version: AsrModelVersion = .v3) async throws -> AsrManager {
        if let cached = managers[version] { return cached }
        if let managerTask { return try await managerTask.value }
        let task = Task { [weak self] () -> AsrManager in
            await MainActor.run { self?.status = "Preparando o Parakeet..." }
            // O handler vem de uma fila qualquer; salta pro main actor antes de tocar o @Published.
            let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] update in
                Task { @MainActor in
                    self?.status = Self.describe(update.phase)
                    self?.progress = update.fractionCompleted
                }
            }
            await MainActor.run {
                self?.status = "Carregando o modelo..."
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
        let manager = try await task.value
        managers[version] = manager
        return manager
    }

    private static func describe(_ phase: DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Consultando os arquivos do modelo..."
        case .downloading(let done, let total):
            return "Baixando Parakeet TDT v3 — \(done) de \(total) arquivos"
        case .compiling(let model):
            return "Compilando \(model) para o Neural Engine..."
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
